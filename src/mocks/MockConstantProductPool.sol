// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IBatchPool} from "../interfaces/IBatchPool.sol";

/// @notice A constant-product (x*y=k) pricing source for the net batch residual.
///         Used by tests and the demo so the batch has a real AMM to clear the
///         residual against. The price returned is the post-trade marginal price
///         for the NET flow only, which is what makes internalised (offsetting)
///         flow inside a batch pay no pool slippage.
contract MockConstantProductPool is IBatchPool {
    uint256 public reserve0;
    uint256 public reserve1;

    constructor(uint256 _reserve0, uint256 _reserve1) {
        reserve0 = _reserve0;
        reserve1 = _reserve1;
    }

    /// @dev Returns the uniform clearing price (token1 per token0 = num/den) for
    ///      the net residual of the batch. If the batch nets to zero on a side,
    ///      the price is the spot reserve ratio (no pool impact at all).
    function clearingPrice(uint256 sell0, uint256 sell1) external view returns (uint128 priceNum, uint128 priceDen) {
        // Net the two directions: only the residual touches the curve.
        if (sell0 >= sell1) {
            uint256 net0 = sell0 - sell1;
            if (net0 == 0) {
                return (uint128(reserve1), uint128(reserve0)); // spot, zero impact
            }
            // marginal price after adding net0 token0 to the pool
            uint256 newR0 = reserve0 + net0;
            return (uint128(reserve1), uint128(newR0));
        } else {
            uint256 net1 = sell1 - sell0;
            uint256 newR1 = reserve1 + net1;
            return (uint128(newR1), uint128(reserve0));
        }
    }
}
