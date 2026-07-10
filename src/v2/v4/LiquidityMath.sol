// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// @dev Single-sided liquidity amounts (the two functions we need from Uniswap's
/// audited LiquidityAmounts library, copied so we don't import test utilities).
library LiquidityMath {
    /// @notice Liquidity for `amount0` of token0 over [sqrtA, sqrtB].
    function getLiquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA));
    }

    /// @notice Liquidity for `amount1` of token1 over [sqrtA, sqrtB].
    function getLiquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) internal pure returns (uint128) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _toUint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA));
    }

    function _toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x, "overflow");
    }
}
