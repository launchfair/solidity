// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";

contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    uint160 public sqrtPriceX96;
    int24 public tick;
    bool public initialized;

    constructor(address token0_, address token1_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function initialize(uint160 sqrtPriceX96_) external {
        require(!initialized, "already initialized");
        initialized = true;
        sqrtPriceX96 = sqrtPriceX96_;
    }

    /// Test hooks: simulate the market moving the pool price.
    function setTick(int24 tick_) external {
        tick = tick_;
    }

    function setSqrtPriceX96(uint160 sqrtPriceX96_) external {
        sqrtPriceX96 = sqrtPriceX96_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, tick, 0, 0, 0, 0, true);
    }
}

contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        require(getPool[tokenA][tokenB][fee] == address(0), "pool exists");
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = address(new MockV3Pool(t0, t1, fee));
        getPool[tokenA][tokenB][fee] = pool;
        getPool[tokenB][tokenA][fee] = pool;
    }
}

/// Pulls the desired amounts on mint (like the real one) and pays out
/// test-configured fee amounts on collect.
contract MockPositionManager {
    struct Minted {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0;
        uint256 amount1;
        address recipient;
    }

    uint256 public nextTokenId = 1;
    mapping(uint256 => Minted) public minted;
    mapping(uint256 => uint256) public collectable0;
    mapping(uint256 => uint256) public collectable1;

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(p.token0 < p.token1, "unsorted");
        tokenId = nextTokenId++;
        if (p.amount0Desired > 0) IERC20(p.token0).transferFrom(msg.sender, address(this), p.amount0Desired);
        if (p.amount1Desired > 0) IERC20(p.token1).transferFrom(msg.sender, address(this), p.amount1Desired);
        minted[tokenId] = Minted({
            token0: p.token0,
            token1: p.token1,
            fee: p.fee,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            amount0: p.amount0Desired,
            amount1: p.amount1Desired,
            recipient: p.recipient
        });
        return (tokenId, uint128(1e18), p.amount0Desired, p.amount1Desired);
    }

    /// Test hook: pretend the position accrued fees.
    function setCollectable(uint256 tokenId, uint256 amount0, uint256 amount1) external {
        collectable0[tokenId] = amount0;
        collectable1[tokenId] = amount1;
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        Minted memory m = minted[p.tokenId];
        amount0 = collectable0[p.tokenId];
        amount1 = collectable1[p.tokenId];
        collectable0[p.tokenId] = 0;
        collectable1[p.tokenId] = 0;
        if (amount0 > 0) IERC20(m.token0).transfer(p.recipient, amount0);
        if (amount1 > 0) IERC20(m.token1).transfer(p.recipient, amount1);
    }
}
