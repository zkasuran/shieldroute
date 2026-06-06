// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @title IBatchPool
/// @notice Minimal pricing interface a ShieldRouter settles its net batch flow
///         against. Implementations return a single clearing price (token1 per
///         token0, as num/den) given the net token0-in and token1-in of a batch.
interface IBatchPool {
    /// @param sell0 total token0 offered into the batch
    /// @param sell1 total token1 offered into the batch
    /// @return priceNum numerator of the uniform clearing price (token1 per token0)
    /// @return priceDen denominator of the uniform clearing price
    function clearingPrice(uint256 sell0, uint256 sell1) external view returns (uint128 priceNum, uint128 priceDen);
}
