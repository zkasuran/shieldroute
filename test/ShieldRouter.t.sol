// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Test} from "forge-std/Test.sol";
import {ShieldRouter} from "../src/ShieldRouter.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IBatchPool} from "../src/interfaces/IBatchPool.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockConstantProductPool} from "../src/mocks/MockConstantProductPool.sol";

contract ShieldRouterTest is Test {
    MockERC20 token0;
    MockERC20 token1;
    MockConstantProductPool pool;
    ShieldRouter router;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint64 constant COMMIT_WINDOW = 100;
    uint64 constant REVEAL_WINDOW = 100;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        // 1:1 reserves so spot price is 1.0
        pool = new MockConstantProductPool(1_000_000 ether, 1_000_000 ether);
        router = new ShieldRouter(
            IERC20(address(token0)), IERC20(address(token1)), IBatchPool(address(pool)), COMMIT_WINDOW, REVEAL_WINDOW
        );

        token0.mint(alice, 1_000 ether);
        token1.mint(bob, 1_000 ether);
        // fund the router so it can pay out fills in the demo/tests
        token0.mint(address(router), 1_000_000 ether);
        token1.mint(address(router), 1_000_000 ether);

        vm.prank(alice);
        token0.approve(address(router), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(router), type(uint256).max);
    }

    function _hash(address t, bool z, uint128 amt, uint128 minOut, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(t, z, amt, minOut, salt));
    }

    function test_batch_opens_in_commit_phase() public view {
        (ShieldRouter.Phase phase,,,,,) = router.getBatch(1);
        assertEq(uint256(phase), uint256(ShieldRouter.Phase.Commit));
        assertEq(router.currentBatchId(), 1);
    }

    function test_full_lifecycle_commit_reveal_settle_claim() public {
        bytes32 salt = keccak256("alice-salt");
        uint128 amt = 100 ether;
        uint128 minOut = 99 ether;

        // commit
        vm.prank(alice);
        router.commit(_hash(alice, true, amt, minOut, salt));

        // close commit window
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        router.closeCommit();

        // reveal (escrows token0)
        vm.prank(alice);
        router.reveal(true, amt, minOut, salt);
        assertEq(token0.balanceOf(address(router)), 1_000_000 ether + amt);

        // settle after reveal window
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);
        router.settle();

        // alice claims ~100 token1 (1:1 spot, single order is the net residual)
        vm.prank(alice);
        router.claim(1);
        assertGt(token1.balanceOf(alice), 99 ether);
    }

    function test_offsetting_flow_clears_at_spot_no_sandwich_loss() public {
        // Alice sells 100 token0, Bob sells 100 token1. They perfectly offset,
        // so the batch nets to zero and BOTH clear at the 1:1 spot price with
        // ZERO pool slippage. This is the core MEV-protection property: a
        // searcher cannot extract from internalised, offsetting flow.
        uint128 amt = 100 ether;
        bytes32 sA = keccak256("a");
        bytes32 sB = keccak256("b");

        vm.prank(alice);
        router.commit(_hash(alice, true, amt, 100 ether, sA));
        vm.prank(bob);
        router.commit(_hash(bob, false, amt, 100 ether, sB));

        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        router.closeCommit();

        vm.prank(alice);
        router.reveal(true, amt, 100 ether, sA);
        vm.prank(bob);
        router.reveal(false, amt, 100 ether, sB);

        vm.warp(block.timestamp + REVEAL_WINDOW + 1);
        router.settle();

        // both get exactly 100 out (1:1), proving zero slippage on offsetting flow
        vm.prank(alice);
        router.claim(1);
        vm.prank(bob);
        router.claim(1);
        assertEq(token1.balanceOf(alice), 100 ether);
        assertEq(token0.balanceOf(bob), 100 ether);
    }

    function test_reveal_reverts_on_wrong_salt() public {
        bytes32 salt = keccak256("real");
        vm.prank(alice);
        router.commit(_hash(alice, true, 100 ether, 99 ether, salt));
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        router.closeCommit();

        vm.prank(alice);
        vm.expectRevert(ShieldRouter.BadReveal.selector);
        router.reveal(true, 100 ether, 99 ether, keccak256("wrong"));
    }

    function test_cannot_commit_after_deadline() public {
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        vm.prank(alice);
        vm.expectRevert(ShieldRouter.DeadlinePassed.selector);
        router.commit(_hash(alice, true, 100 ether, 99 ether, keccak256("s")));
    }

    function test_cannot_reveal_in_commit_phase() public {
        bytes32 salt = keccak256("s");
        vm.prank(alice);
        router.commit(_hash(alice, true, 100 ether, 99 ether, salt));
        vm.prank(alice);
        vm.expectRevert(ShieldRouter.WrongPhase.selector);
        router.reveal(true, 100 ether, 99 ether, salt);
    }

    function test_double_commit_reverts() public {
        bytes32 salt = keccak256("s");
        vm.startPrank(alice);
        router.commit(_hash(alice, true, 100 ether, 99 ether, salt));
        vm.expectRevert(ShieldRouter.AlreadyCommitted.selector);
        router.commit(_hash(alice, true, 100 ether, 99 ether, salt));
        vm.stopPrank();
    }

    function test_settle_opens_next_batch() public {
        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        router.closeCommit();
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);
        router.settle();
        assertEq(router.currentBatchId(), 2);
        (ShieldRouter.Phase phase,,,,,) = router.getBatch(2);
        assertEq(uint256(phase), uint256(ShieldRouter.Phase.Commit));
    }

    function test_slippage_bound_reverts_settlement() public {
        // Alice sells a large amount alone; demand an impossible minOut so the
        // single-sided residual price trips the slippage guard.
        uint128 amt = 500_000 ether;
        bytes32 salt = keccak256("big");
        token0.mint(alice, amt);
        vm.prank(alice);
        router.commit(_hash(alice, true, amt, amt, salt)); // minOut == amountIn, impossible with impact

        vm.warp(block.timestamp + COMMIT_WINDOW + 1);
        router.closeCommit();
        vm.prank(alice);
        router.reveal(true, amt, amt, salt);
        vm.warp(block.timestamp + REVEAL_WINDOW + 1);

        vm.expectRevert();
        router.settle();
    }
}
