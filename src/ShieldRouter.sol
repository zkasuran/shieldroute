// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20} from "./interfaces/IERC20.sol";
import {IBatchPool} from "./interfaces/IBatchPool.sol";

/// @title ShieldRouter
/// @notice MEV-protected swap execution for Mantle. Orders are submitted as
///         commitments (a hash), grouped into a batch, then revealed and settled
///         together at a single uniform clearing price. Because no order's
///         direction, size or price is visible until the batch closes, and every
///         order in a batch clears at the same price, a searcher cannot sandwich
///         or front-run an individual order inside the batch.
/// @dev    MVP scope: one token pair per router, market orders with a
///         user-supplied minimum-out slippage bound. The clearing price comes
///         from the bound `IBatchPool` after net order flow is applied, so the
///         batch internalises offsetting flow before touching the pool.
contract ShieldRouter {
    /// @dev Lifecycle of a single batch.
    enum Phase {
        Commit, // accepting commitments
        Reveal, // commitments locked, accepting reveals
        Settled // cleared, funds claimable
    }

    struct Commitment {
        bytes32 hash; // keccak256(trader, zeroForOne, amountIn, minOut, salt)
        bool revealed;
        bool zeroForOne; // true: sell token0 for token1
        uint128 amountIn;
        uint128 minOut;
        uint128 amountOut; // filled at settlement
        bool claimed;
    }

    struct Batch {
        Phase phase;
        uint64 commitDeadline;
        uint64 revealDeadline;
        uint128 clearingPriceNum; // token1 out per token0 in, as num/den
        uint128 clearingPriceDen;
        address[] traders;
    }

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    IBatchPool public immutable pool;

    /// @notice Duration of each phase in seconds, set at construction.
    uint64 public immutable commitWindow;
    uint64 public immutable revealWindow;

    uint256 public currentBatchId;
    mapping(uint256 batchId => Batch) internal _batches;
    mapping(uint256 batchId => mapping(address trader => Commitment)) internal _commitments;

    event BatchOpened(uint256 indexed batchId, uint64 commitDeadline, uint64 revealDeadline);
    event Committed(uint256 indexed batchId, address indexed trader, bytes32 hash);
    event Revealed(uint256 indexed batchId, address indexed trader, bool zeroForOne, uint128 amountIn, uint128 minOut);
    event Settled(uint256 indexed batchId, uint128 priceNum, uint128 priceDen, uint256 orders);
    event Claimed(uint256 indexed batchId, address indexed trader, uint128 amountOut);

    error WrongPhase();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error AlreadyCommitted();
    error NoCommitment();
    error AlreadyRevealed();
    error BadReveal();
    error SlippageExceeded(uint128 got, uint128 minOut);
    error NothingToClaim();
    error TransferFailed();

    constructor(IERC20 _token0, IERC20 _token1, IBatchPool _pool, uint64 _commitWindow, uint64 _revealWindow) {
        token0 = _token0;
        token1 = _token1;
        pool = _pool;
        commitWindow = _commitWindow;
        revealWindow = _revealWindow;
        _openBatch();
    }

    // --------------------------------------------------------------------- //
    // Commit                                                                //
    // --------------------------------------------------------------------- //

    /// @notice Submit a hidden order. `hash` binds the order to the trader and a
    ///         secret salt so it cannot be copied or front-run before reveal.
    function commit(bytes32 hash) external {
        Batch storage b = _batches[currentBatchId];
        if (b.phase != Phase.Commit) revert WrongPhase();
        if (block.timestamp > b.commitDeadline) revert DeadlinePassed();

        Commitment storage c = _commitments[currentBatchId][msg.sender];
        if (c.hash != bytes32(0)) revert AlreadyCommitted();

        c.hash = hash;
        b.traders.push(msg.sender);
        emit Committed(currentBatchId, msg.sender, hash);
    }

    /// @notice Move the current batch from Commit to Reveal once the commit
    ///         window has elapsed. Permissionless so any keeper (or agent) can
    ///         advance the batch.
    function closeCommit() external {
        Batch storage b = _batches[currentBatchId];
        if (b.phase != Phase.Commit) revert WrongPhase();
        if (block.timestamp <= b.commitDeadline) revert DeadlineNotPassed();
        b.phase = Phase.Reveal;
    }

    // --------------------------------------------------------------------- //
    // Reveal                                                                //
    // --------------------------------------------------------------------- //

    /// @notice Reveal a previously committed order and escrow the input tokens.
    function reveal(bool zeroForOne, uint128 amountIn, uint128 minOut, bytes32 salt) external {
        Batch storage b = _batches[currentBatchId];
        if (b.phase != Phase.Reveal) revert WrongPhase();
        if (block.timestamp > b.revealDeadline) revert DeadlinePassed();

        Commitment storage c = _commitments[currentBatchId][msg.sender];
        if (c.hash == bytes32(0)) revert NoCommitment();
        if (c.revealed) revert AlreadyRevealed();

        bytes32 expected = keccak256(abi.encode(msg.sender, zeroForOne, amountIn, minOut, salt));
        if (expected != c.hash) revert BadReveal();

        c.revealed = true;
        c.zeroForOne = zeroForOne;
        c.amountIn = amountIn;
        c.minOut = minOut;

        IERC20 tokenIn = zeroForOne ? token0 : token1;
        _safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);

        emit Revealed(currentBatchId, msg.sender, zeroForOne, amountIn, minOut);
    }

    // --------------------------------------------------------------------- //
    // Settle                                                                //
    // --------------------------------------------------------------------- //

    /// @notice Close the reveal window, net the batch flow, settle the residual
    ///         against the pool at one uniform clearing price, and assign each
    ///         revealed order its fill. Permissionless.
    /// @dev    Uses `block.timestamp` only to gate minutes-long phase windows. A
    ///         validator can nudge the timestamp by a few seconds, which cannot
    ///         change which orders are in the batch or their uniform price, so
    ///         the standard batch-auction timestamp assumption is safe here.
    function settle() external {
        Batch storage b = _batches[currentBatchId];
        if (b.phase != Phase.Reveal) revert WrongPhase();
        if (block.timestamp <= b.revealDeadline) revert DeadlineNotPassed();

        // Net the revealed flow: sum token0-in and token1-in across the batch.
        uint256 sell0;
        uint256 sell1;
        uint256 n = b.traders.length;
        for (uint256 i = 0; i < n; i++) {
            Commitment storage c = _commitments[currentBatchId][b.traders[i]];
            if (!c.revealed) continue;
            if (c.zeroForOne) sell0 += c.amountIn;
            else sell1 += c.amountIn;
        }

        // The pool prices only the net residual, so internalised flow never
        // hits the AMM and pays no sandwich-able slippage.
        (uint128 priceNum, uint128 priceDen) = pool.clearingPrice(sell0, sell1);
        b.clearingPriceNum = priceNum;
        b.clearingPriceDen = priceDen;

        // Assign fills at the single clearing price (token1 per token0 = num/den).
        for (uint256 i = 0; i < n; i++) {
            Commitment storage c = _commitments[currentBatchId][b.traders[i]];
            if (!c.revealed) continue;
            uint128 out;
            if (c.zeroForOne) {
                out = uint128((uint256(c.amountIn) * priceNum) / priceDen);
            } else {
                out = uint128((uint256(c.amountIn) * priceDen) / priceNum);
            }
            if (out < c.minOut) revert SlippageExceeded(out, c.minOut);
            c.amountOut = out;
        }

        b.phase = Phase.Settled;
        emit Settled(currentBatchId, priceNum, priceDen, n);

        _openBatch();
    }

    // --------------------------------------------------------------------- //
    // Claim                                                                 //
    // --------------------------------------------------------------------- //

    /// @notice Withdraw the filled output for a settled order.
    function claim(uint256 batchId) external {
        Batch storage b = _batches[batchId];
        if (b.phase != Phase.Settled) revert WrongPhase();
        Commitment storage c = _commitments[batchId][msg.sender];
        if (!c.revealed || c.claimed || c.amountOut == 0) revert NothingToClaim();

        c.claimed = true;
        IERC20 tokenOut = c.zeroForOne ? token1 : token0;
        _safeTransfer(tokenOut, msg.sender, c.amountOut);
        emit Claimed(batchId, msg.sender, c.amountOut);
    }

    // --------------------------------------------------------------------- //
    // Views                                                                 //
    // --------------------------------------------------------------------- //

    function getBatch(uint256 batchId)
        external
        view
        returns (
            Phase phase,
            uint64 commitDeadline,
            uint64 revealDeadline,
            uint128 priceNum,
            uint128 priceDen,
            uint256 orders
        )
    {
        Batch storage b = _batches[batchId];
        return (b.phase, b.commitDeadline, b.revealDeadline, b.clearingPriceNum, b.clearingPriceDen, b.traders.length);
    }

    function getCommitment(uint256 batchId, address trader) external view returns (Commitment memory) {
        return _commitments[batchId][trader];
    }

    // --------------------------------------------------------------------- //
    // Internal                                                              //
    // --------------------------------------------------------------------- //

    function _openBatch() internal {
        currentBatchId += 1;
        Batch storage b = _batches[currentBatchId];
        b.phase = Phase.Commit;
        b.commitDeadline = uint64(block.timestamp) + commitWindow;
        b.revealDeadline = b.commitDeadline + revealWindow;
        emit BatchOpened(currentBatchId, b.commitDeadline, b.revealDeadline);
    }

    /// @dev Checked ERC20 transfer: reverts on a false return or a failed call,
    ///      so a non-reverting non-standard token cannot silently skip a payout.
    function _safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
