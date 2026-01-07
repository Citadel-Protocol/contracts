// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import {ISynthereumMultiLpLiquidityPool} from "../../src/pool/interfaces/IMultiLpLiquidityPool.sol";
import {ILendingStorageManager} from "../../src/lending-module/interfaces/ILendingStorageManager.sol";
import {ISynthereumFinder} from "../../src/interfaces/IFinder.sol";
import {ILendingManager} from "../../src/lending-module/interfaces/ILendingManager.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";
import {ICompoundToken} from "../../src/interfaces/ICToken.sol";
import {SynthereumInterfaces} from "../../src/Constants.sol";

/// @title MultiLpTestHelpers
/// @notice Helper functions for MultiLpLiquidityPool tests
library MultiLpTestHelpers {
    /// @notice Calculates fee, net amount, and tokens for minting
    function calculateFeeAndSynthAssetForMint(
        uint256 feePrc,
        uint256 collAmount,
        uint256 price,
        uint8 collateralDecimals,
        uint256 preciseUnit
    )
        internal
        pure
        returns (uint256 feeAmount, uint256 netAmount, uint256 tokensAmount)
    {
        feeAmount = (collAmount * feePrc) / preciseUnit;
        netAmount = collAmount - feeAmount;
        uint256 factor = 10 ** (18 - collateralDecimals);
        tokensAmount = (netAmount * factor * preciseUnit) / price;
    }

    /// @notice Calculates fee, net amount, and collateral for redeeming
    function calculateFeeAndCollateralForRedeem(
        uint256 feePrc,
        uint256 synthAmount,
        uint256 price,
        uint8 collateralDecimals,
        uint256 preciseUnit
    )
        internal
        pure
        returns (uint256 feeAmount, uint256 netAmount, uint256 collAmount)
    {
        feeAmount = (synthAmount * feePrc) / preciseUnit;
        netAmount = synthAmount - feeAmount;
        uint256 factor = 10 ** (18 - collateralDecimals);
        collAmount = (netAmount * price) / preciseUnit / factor;
    }

    function getLessCollateralizedLP(
        ISynthereumMultiLpLiquidityPool poolInstance
    )
        public
        view
        returns (address lessCollateralizedLP, uint256 coverage, uint256 tokens)
    {
        address[] memory activeLps = poolInstance.getActiveLPs();
        lessCollateralizedLP = activeLps[0];
        coverage = poolInstance.positionLPInfo(lessCollateralizedLP).coverage;
        tokens = poolInstance
            .positionLPInfo(lessCollateralizedLP)
            .tokensCollateralized;
        for (uint8 i = 0; i < activeLps.length; ++i) {
            if (
                poolInstance
                    .positionLPInfo(activeLps[i])
                    .actualCollateralAmount <
                poolInstance
                    .positionLPInfo(lessCollateralizedLP)
                    .actualCollateralAmount
            ) {
                lessCollateralizedLP = activeLps[i];
                tokens = poolInstance
                    .positionLPInfo(activeLps[i])
                    .tokensCollateralized;
                coverage = poolInstance.positionLPInfo(activeLps[i]).coverage;
            }
        }
    }

    /// @notice Updates pool positions and returns accumulated interest
    /// @param _pool The pool contract address
    /// @param _finder The SynthereumFinder contract
    /// @return poolInterest The accumulated pool interest
    function updatePositions(
        address _pool,
        ISynthereumFinder _finder
    ) internal returns (uint256 poolInterest) {
        ISynthereumMultiLpLiquidityPool poolContract = ISynthereumMultiLpLiquidityPool(_pool);
        ILendingManager lendingManager = ILendingManager(
            _finder.getImplementationAddress(SynthereumInterfaces.LendingManager)
        );
        
        (poolInterest, , , ) = lendingManager.getAccumulatedInterest(_pool);
        poolContract.updatePositions();
    }

    struct TotalCollateral {
        uint256 usersCollateral;
        uint256 lpsCollateral;
        uint256 totalCollateral;
    }

    struct Interest {
        uint256 poolInterest;
        uint256 commissionInterest;
        uint256 buybackInterest;
    }

    struct Amounts {
        uint256 totalSynthTokens;
        uint256 totCapacity;
        uint256 poolBearingBalance;
        uint256 poolCollBalance;
        uint256 expectedBearing;
        uint256 poolTotCollateral;
        uint256 expectedCollateral;
    }

    function getAllPoolData(
        ISynthereumMultiLpLiquidityPool poolInstance,
        ISynthereumFinder finder
    )
        public
        view
        returns (
            ILendingStorageManager.PoolStorage memory poolData,
            TotalCollateral memory totColl,
            Amounts memory amounts,
            ISynthereumMultiLpLiquidityPool.LPInfo[] memory lpsInfo,
            Interest memory interest
        )
    {
        //We need to get the storage manager and lending manager from the finder
        ILendingStorageManager storageManager = ILendingStorageManager(
            finder.getImplementationAddress(
               SynthereumInterfaces.LendingStorageManager
            )
        );
        ILendingManager lendingManager = ILendingManager(
            finder.getImplementationAddress(SynthereumInterfaces.LendingManager)
        );

        //Then we get the pool data
        poolData = storageManager.getPoolStorage(address(poolInstance));

        //Then we get the total collateral amounts
        (
            totColl.usersCollateral,
            totColl.lpsCollateral,
            totColl.totalCollateral
        ) = poolInstance.totalCollateralAmount();
        (
            totColl.usersCollateral,
            totColl.lpsCollateral,
            totColl.totalCollateral
        ) = poolInstance.totalCollateralAmount();

        //Then we get the amounts

        amounts.totalSynthTokens = poolInstance.totalSyntheticTokens();
        amounts.totCapacity = poolInstance.maxTokensCapacity();
        amounts.poolBearingBalance = IERC20(poolData.interestBearingToken)
            .balanceOf(address(poolInstance));
        amounts.poolCollBalance = IERC20(poolData.collateral).balanceOf(
            address(poolInstance)
        );

        //Then we get the interest
        (
            interest.poolInterest,
            interest.commissionInterest,
            interest.buybackInterest,

        ) = lendingManager.getAccumulatedInterest(address(poolInstance));

        //Then we get the pool total collateral adding the interest and the unclaimed dao interest

        amounts.poolTotCollateral =
            poolData.collateralDeposited +
            poolData.unclaimedDaoJRT +
            poolData.unclaimedDaoCommission +
            interest.poolInterest +
            interest.commissionInterest +
            interest.buybackInterest;
        (amounts.expectedBearing, ) = lendingManager.collateralToInterestToken(
            address(poolInstance),
            amounts.poolTotCollateral
        );
        (amounts.expectedCollateral, ) = lendingManager
            .interestTokenToCollateral(
                address(poolInstance),
                amounts.poolBearingBalance
            );

        //Then we get the lps info
        address[] memory _lps = poolInstance.getActiveLPs();
        lpsInfo = new ISynthereumMultiLpLiquidityPool.LPInfo[](_lps.length);
        for (uint256 j = 0; j < _lps.length; j++) {
            lpsInfo[j] = poolInstance.positionLPInfo(_lps[j]);
        }
    }

    /// @notice Updates the lending rate for Ovix or Midas modules by calling exchangeRateCurrent on the bearing token
    /// @param pool The pool contract
    function updateLendingRate(address pool) internal {
        // Get lending module name and bearing token address
        (string memory lendingModule, address bearingTokenAddr) = ISynthereumMultiLpLiquidityPool(pool).lendingProtocolInfo();
        ICompoundToken(bearingTokenAddr).exchangeRateCurrent();
    }
}
