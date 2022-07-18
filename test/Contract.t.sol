// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "./FullMath.sol";
import "./TickMath.sol";

interface IUniswapV3Pool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
    function liquidity() external view returns (uint128);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives);
    function observations(uint256 index) external view returns (uint32 blockTimestamp, int56 tickCumulative, uint160 liquidityCumulative, bool initialized);
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external;
}

library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}

contract UniswapV3Oracle is Test {
  uint256 public constant EXP_SCALE = 1e18;

  struct AssetCache {
    address underlying;

    uint112 totalBalances;
    uint144 totalBorrows;

    uint96 reserveBalance;

    uint interestAccumulator;

    uint40 lastInterestAccumulatorUpdate;
    uint8 underlyingDecimals;
    uint32 interestRateModel;
    int96 interestRate;
    uint32 reserveFee;
    uint16 pricingType;
    uint32 pricingParameters;

    uint poolSize; // result of calling balanceOf on underlying (in external units)

    uint underlyingDecimalsScaler;
    uint maxExternalAmount;
  }

  address public constant DAI_ETH = address(0x60594a405d53811d3BC4766596EFD80fd545A270);
  address public constant WBTC_ETH = address(0xCBCdF9626bC03E24f779434178A73a0B4bad62eD);
  address public constant WBTC_DAI = address(0x391E8501b626C623d39474AfcA6f9e46c2686649);

  uint32 public constant anchorPeriod = 30 minutes;

  function priceFromTick(bool zeroToOne, uint256 scale, int56[] memory tickCumulatives) public view returns (uint256) {
    int56 anchorPeriodI = int56(uint56(anchorPeriod));
    int56 timeWeightedAverageTickS56 = (tickCumulatives[1] - tickCumulatives[0]) / anchorPeriodI;

    int24 timeWeightedAverageTick = int24(timeWeightedAverageTickS56);

    if(!zeroToOne) {
      timeWeightedAverageTick = -timeWeightedAverageTick;
    }

    uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(timeWeightedAverageTick);
    uint256 twapX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);

    return FullMath.mulDiv(scale, twapX96, FixedPoint96.Q96);
  }

  function testSlot() public {
    // Get the 30 minute (anchorPeriod) TWAP tick price of Uniswap V3 pools
    // DAI:ETH, DAI:BTC, ETH:BTC and use that to get an ETH price based on
    // all three pools. 1. get the ETH price in DAI, 2. get the BTC price in ETH
    // 3. get the BTC price in DAI. 4. Get ETH price in BTC:DAI.

    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = anchorPeriod;

    uint256 daiEthPrice;
    uint256 daiBtcPrice;
    uint256 btcEthPrice;

    { // DAI:ETH
      // Price of ETH denominated in DAI
      bool zeroToOne = false;
      (int56[] memory tickCumulatives, ) = IUniswapV3Pool(DAI_ETH).observe(secondsAgos);
      uint256 price = priceFromTick(zeroToOne, 1e18, tickCumulatives);
      emit log_uint(price);
      daiEthPrice = price;
    }

    { // WBTC:ETH
      // Price of BTC denominated in ETH
      bool zeroToOne = true;
      (int56[] memory tickCumulatives, ) = IUniswapV3Pool(WBTC_ETH).observe(secondsAgos);
      uint256 price = priceFromTick(zeroToOne, 1e8, tickCumulatives);
      emit log_uint(price);
      btcEthPrice = price;
    }

    { // WBTC:DAI
      // Price of BTC denominated in DAI
      bool zeroToOne = true;
      (int56[] memory tickCumulatives, ) = IUniswapV3Pool(WBTC_DAI).observe(secondsAgos);
      uint256 price = priceFromTick(zeroToOne, 1e8, tickCumulatives);
      emit log_uint(price);
      daiBtcPrice = price;
    }

    uint256 crossOverPrice = daiBtcPrice * 1e18 / btcEthPrice;
    uint256 avePrice = (crossOverPrice + daiEthPrice) / 2;
    
    emit log_uint(avePrice);
  }
}
