// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import "forge-std/Test.sol";

import {SynthereumFinder} from "../../src/Finder.sol"; // Assuming Finder.sol is in src directory
import {SynthereumDeployer} from "../../src/Deployer.sol";
import {StandardAccessControlEnumerable} from "../../src/roles/StandardAccessControlEnumerable.sol";
import {SynthereumPriceFeed} from "../../src/oracle/PriceFeed.sol";
import {SynthereumManager} from "../../src/Manager.sol";
import {SynthereumCollateralWhitelist} from "../../src/CollateralWhitelist.sol";
import {SynthereumIdentifierWhitelist} from "../../src/IdentifierWhitelist.sol";
import {SynthereumFactoryVersioning} from "../../src/FactoryVersioning.sol";
import {SynthereumTrustedForwarder} from "../../src/TrustedForwarder.sol";
import {SynthereumChainlinkPriceFeed} from "../../src/oracle/implementations/ChainlinkPriceFeed.sol";
import {SynthereumPriceFeedImplementation} from "../../src/oracle/implementations/PriceFeedImplementation.sol";
import {SynthereumSyntheticTokenPermitFactory} from "../../src/tokens/factories/SyntheticTokenPermitFactory.sol";
import {SynthereumMultiLpLiquidityPoolFactory} from "../../src/pool/MultiLpLiquidityPoolFactory.sol";
import {SynthereumMultiLpLiquidityPool} from "../../src/pool/MultiLpLiquidityPool.sol";
import {LendingStorageManager} from "../../src/lending-module/LendingStorageManager.sol";
import {LendingManager} from "../../src/lending-module/LendingManager.sol";
import {ILendingManager} from "../../src/lending-module/interfaces/ILendingManager.sol";
import {ILendingStorageManager} from "../../src/lending-module/interfaces/ILendingStorageManager.sol";
import {SynthereumPoolRegistry} from "../../src/registries/PoolRegistry.sol";

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";
import {ISynthereumMultiLpLiquidityPool} from "../../src/pool/interfaces/IMultiLpLiquidityPool.sol";
import {IStandardERC20} from "../../src/base/interfaces/IStandardERC20.sol";
import {IMintableBurnableERC20} from "../../src/tokens/interfaces/IMintableBurnableERC20.sol";
import {CompoundModule} from "../../src/lending-module/lending-modules/Compound.sol";

import {IPoolVault} from "../../src/pool/common/interfaces/IPoolVault.sol";

import {ICompoundToken, IComptroller} from "../../src/interfaces/ICToken.sol";

import {MultiLpTestHelpers} from "../helpers/MultiLpTestHelpers.sol";

contract MultiLpLiquidityPool_Test is Test {
    struct Roles {
        address admin;
        address maintainer;
        address[] liquidityProviders;
        address excessBeneficiary;
        address dao;
        address firstWrongAddress;
        address minter;
        address burner;
        address randomGuy;
    }

    struct LendingManagerParams {
        string lendingId;
        address interestBearingToken;
        uint64 daoInterestShare;
        uint64 jrtBuybackShare;
    }

    struct PoolParams {
        uint8 version;
        address collateralToken;
        string syntheticName;
        string syntheticSymbol;
        address syntheticToken;
        StandardAccessControlEnumerable.Roles roles;
        uint64 fee;
        bytes32 priceIdentifier;
        uint128 overCollateralRequirement;
        uint64 liquidationReward;
        LendingManagerParams lendingManagerParams;
    }

    // State variables to store the values
    address public collateralAddress =
        0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409; // FDUSD
    string public priceIdentifier = "EURUSD";
    string public syntheticName = "Citadel Euro";
    string public syntheticSymbol = "cEUR";
    string public lendingId = "Compound";
    uint64 daoInterestShare = 0.1 ether;
    uint64 jrtBuybackShare = 0.6 ether;
    uint8 poolVersion;
    uint128 overCollateralRequirement = 0.05 ether;
    uint64 liquidationReward = 0.05 ether;  // 5%
    uint64 feePercentage = 0.002 ether; // 0.2% fee
    uint32[2] feeProportions;
    uint256 capMintAmount = 1_000_000 ether;
    uint64 maxSpread = 0.001 ether;

    address debtTokenAddress = 0xC4eF4229FEc74Ccfe17B2bdeF7715fAC740BA0ba; // Venus FDUSD debt token
    ICompoundToken debtToken = ICompoundToken(debtTokenAddress);

    LendingManagerParams lendingManagerParams;
    PoolParams poolParams;

    event PoolDeployed(uint8 indexed poolVersion, address indexed newPool);

    CompoundModule venusModule;

    struct Fee {
        uint64 feePercentage;
        address[2] feeRecipients;
        uint32[2] feeProportions;
    }

    address[] lps;
    Roles public roles =
        Roles({
            admin: makeAddr("admin"),
            maintainer: makeAddr("maintainer"),
            liquidityProviders: lps,
            excessBeneficiary: makeAddr("excessBeneficiary"),
            dao: makeAddr("dao"),
            firstWrongAddress: makeAddr("firstWrongAddress"),
            minter: makeAddr("minter"),
            burner: makeAddr("burner"),
            randomGuy: makeAddr("randomGuy")
        });
    Fee public fee;
    Fee public selfMintingFee;

    SynthereumDeployer deployer;

    SynthereumSyntheticTokenPermitFactory tokenFactory;

    SynthereumFinder finder;
    SynthereumManager manager;
    LendingManager lendingManager;
    LendingStorageManager lendingStorageManager;
    address aggregator = 0x0bf79F617988C472DcA68ff41eFe1338955b9A80; // Chainlink bsc data feed address;
    SynthereumPriceFeed priceFeed;
    SynthereumChainlinkPriceFeed synthereumChainlinkPriceFeed;
    SynthereumMultiLpLiquidityPoolFactory poolFactory;
    SynthereumTrustedForwarder forwarderInstance;
    SynthereumCollateralWhitelist collateralWhitelist;
    SynthereumIdentifierWhitelist identifierWhitelist;
    SynthereumPoolRegistry poolRegistry;
    SynthereumFactoryVersioning factoryVersioning;
    SynthereumMultiLpLiquidityPool pool;
    IERC20 synthToken;

    constructor() {
        lps.push(makeAddr("firstLP"));
        lps.push(makeAddr("secondLP"));
        roles.liquidityProviders = lps;
        finder = new SynthereumFinder(
            SynthereumFinder.Roles(roles.admin, roles.maintainer)
        );
        priceFeed = new SynthereumPriceFeed(
            finder,
            StandardAccessControlEnumerable.Roles(roles.admin, roles.maintainer)
        );
        poolVersion = 1;
        vm.startPrank(roles.maintainer);

        synthereumChainlinkPriceFeed = new SynthereumChainlinkPriceFeed(
            finder,
            StandardAccessControlEnumerable.Roles(roles.admin, roles.maintainer)
        );

        finder.changeImplementationAddress(
            bytes32(bytes("PriceFeed")),
            address(priceFeed)
        );
        priceFeed.addOracle("chainlink", address(synthereumChainlinkPriceFeed));
        maxSpread = 0.001 ether;
        synthereumChainlinkPriceFeed.setPair(
            priceIdentifier,
            SynthereumPriceFeedImplementation.Type(1),
            aggregator,
            0,
            "",
            maxSpread
        );
        string[] memory emptyArray;
        priceFeed.setPair(
            priceIdentifier,
            SynthereumPriceFeed.Type(1),
            "chainlink",
            emptyArray
        );
        collateralWhitelist = new SynthereumCollateralWhitelist(
            SynthereumCollateralWhitelist.Roles(roles.admin, roles.maintainer)
        );
        collateralWhitelist.addToWhitelist(collateralAddress);
        finder.changeImplementationAddress(
            bytes32(bytes("CollateralWhitelist")),
            address(collateralWhitelist)
        );
        identifierWhitelist = new SynthereumIdentifierWhitelist(
            SynthereumIdentifierWhitelist.Roles(roles.admin, roles.maintainer)
        );
        identifierWhitelist.addToWhitelist(bytes32(bytes(priceIdentifier)));
        finder.changeImplementationAddress(
            bytes32(bytes("IdentifierWhitelist")),
            address(identifierWhitelist)
        );
        tokenFactory = new SynthereumSyntheticTokenPermitFactory(
            address(finder)
        );
        finder.changeImplementationAddress(
            bytes32(bytes("TokenFactory")),
            address(tokenFactory)
        );

        lendingStorageManager = new LendingStorageManager(finder);
        finder.changeImplementationAddress(
            bytes32(bytes("LendingStorageManager")),
            address(lendingStorageManager)
        );

        lendingManager = new LendingManager(
            finder,
            ILendingManager.Roles(roles.admin, roles.maintainer)
        );
        finder.changeImplementationAddress(
            bytes32(bytes("LendingManager")),
            address(lendingManager)
        );

        venusModule = new CompoundModule();

        ILendingStorageManager.LendingInfo
            memory lendingInfo = ILendingStorageManager.LendingInfo(
                address(venusModule),
                ""
            ); // address of venus pool on bsc

        lendingManager.setLendingModule("Compound", lendingInfo);

        poolRegistry = new SynthereumPoolRegistry(finder);
        finder.changeImplementationAddress(
            bytes32(bytes("PoolRegistry")),
            address(poolRegistry)
        );

        manager = new SynthereumManager(
            finder,
            SynthereumManager.Roles(roles.admin, roles.maintainer)
        );

        // Update the Manager implementation address in the SynthereumFinder
        finder.changeImplementationAddress(
            bytes32(bytes("Manager")),
            address(manager)
        );
        forwarderInstance = new SynthereumTrustedForwarder();
        finder.changeImplementationAddress(
            bytes32(bytes("TrustedForwarder")),
            address(forwarderInstance)
        );

        // Deploy FactoryVersioning and set roles
        factoryVersioning = new SynthereumFactoryVersioning(
            SynthereumFactoryVersioning.Roles(roles.admin, roles.maintainer)
        );

        SynthereumMultiLpLiquidityPool poolImplementation = new SynthereumMultiLpLiquidityPool();

        // Deploy the pool factory with the pool implementation address
        poolFactory = new SynthereumMultiLpLiquidityPoolFactory(
            address(finder),
            address(poolImplementation) // Ensure this implementation exists
        );

        // Register the pool factory in FactoryVersioning for the correct version
        factoryVersioning.setFactory(
            bytes32(bytes("PoolFactory")),
            poolVersion,
            address(poolFactory)
        );

        finder.changeImplementationAddress(
            bytes32(bytes("FactoryVersioning")),
            address(factoryVersioning)
        );

        // Define pool version and lending manager parameters
        lendingManagerParams = LendingManagerParams(
            lendingId,
            debtTokenAddress,
            daoInterestShare,
            jrtBuybackShare
        );

        // Define pool parameters, setting `liquidityProvider` to `address(0)`
        poolParams = PoolParams(
            poolVersion,
            collateralAddress,
            syntheticName,
            syntheticSymbol,
            address(0), // Placeholder for liquidity provider address
            StandardAccessControlEnumerable.Roles(
                roles.admin,
                roles.maintainer
            ),
            feePercentage,
            bytes32(bytes(priceIdentifier)),
            overCollateralRequirement,
            liquidationReward,
            lendingManagerParams
        );

        // Deploy SynthereumDeployer contract with admin and maintainer roles
        deployer = new SynthereumDeployer(
            finder,
            SynthereumDeployer.Roles(roles.admin, roles.maintainer)
        );
        // Update Deployer and FactoryVersioning implementations in SynthereumFinder
        finder.changeImplementationAddress(
            bytes32(bytes("Deployer")),
            address(deployer)
        );

        // setUpPriceMocks();

        vm.stopPrank();
    }

    // function setUpPriceMocks() internal {
    //     // Mock all price oracle calls for the debt token
    //     bytes4 getUnderlyingPriceSelector = bytes4(keccak256("getUnderlyingPrice(address)"));
    //     uint256 mockPrice = 1.14 ether; // 1.14:1 price
        
    //     // Mock the main price oracle
    //     vm.mockCall(
    //         address(0x90d840f463c4E341e37B1D51b1aB16Bc5b34865C),
    //         abi.encodeWithSelector(getUnderlyingPriceSelector, debtTokenAddress),
    //         abi.encode(mockPrice)
    //     );
        
    //     // Mock the comptroller
    //     vm.mockCall(
    //         address(0xfD36E2c2a6789Db23113685031d7F16329158384),
    //         abi.encodeWithSelector(getUnderlyingPriceSelector, debtTokenAddress),
    //         abi.encode(mockPrice)
    //     );
        
    //     // Mock the risk model
    //     vm.mockCall(
    //         address(0x6592b5DE802159F3E74B2486b091D11a8256ab8A),
    //         abi.encodeWithSelector(getUnderlyingPriceSelector, debtTokenAddress),
    //         abi.encode(mockPrice)
    //     );
    // }

    modifier whenTheProtocolWantsToCreateAPool() {
        // it should deploy the pool implementation correctly
        vm.prank(roles.maintainer);
        vm.expectEmit(true, false, false, false);
        emit PoolDeployed(1, address(0x000000000000));
        pool = SynthereumMultiLpLiquidityPool(
            address(deployer.deployPool(poolVersion, abi.encode(poolParams)))
        );
        _;
    }

    modifier whenPoolIsInitialized() {
        // it should deploy the pool implementation correctly
        // vm.startPrank(roles.maintainer);
        //  vm.expectEmit(true, false, false, false);
        // emit PoolDeployed(1, address(0x000000000000));
        // pool = SynthereumMultiLpLiquidityPool(address(deployer.deployPool(poolVersion, abi.encode(poolParams))));
        // vm.stopPrank();
        _;
    }

    function test_WhenPoolIsInitialized()
        external
        whenTheProtocolWantsToCreateAPool
        whenPoolIsInitialized
    {
        //Check version
        assertEq(pool.version(), poolVersion, "Wrong version");
        //Check finder
        assertEq(
            address(pool.synthereumFinder()),
            address(finder),
            "Wrong finder"
        );
        //Check collateral
        assertEq(
            address(pool.collateralToken()),
            collateralAddress,
            "Wrong collateral"
        );
        //Check synthetic name
        synthToken = IERC20(address(pool.syntheticToken()));
        assertEq(synthToken.name(), syntheticName, "Wrong synthetic name");
        //Check synthetic symbol
        assertEq(
            synthToken.symbol(),
            syntheticSymbol,
            "Wrong synthetic symbol"
        );
        //Check lendingId
        (string memory storedLendingId, ) = pool.lendingProtocolInfo();
        assertEq(storedLendingId, lendingId, "Wrong lendingId");
        //Check overcollateral
        assertEq(
            pool.collateralRequirement(),
            1 ether + overCollateralRequirement,
            "Wrong overCollateral"
        );
        //Check liquidation reward
        assertEq(
            pool.liquidationReward(),
            liquidationReward,
            "Wrong liquidation reward"
        );
        //Check fee percentage
        assertEq(pool.feePercentage(), feePercentage, "Wrong fee percentage");
    }

    function test_GivenInitializingTheLogicContractDirectly()
        external
        whenTheProtocolWantsToCreateAPool
        whenPoolIsInitialized
    {}

    function test_GivenRe_initializingAnAlreadyInitializedPool()
        external
        whenTheProtocolWantsToCreateAPool
        whenPoolIsInitialized
    {
        // it should revert with "already-initialized"
        ISynthereumMultiLpLiquidityPool.InitializationParams
            memory initialisationParams = ISynthereumMultiLpLiquidityPool
                .InitializationParams({
                    finder: finder,
                    version: poolVersion,
                    collateralToken: IStandardERC20(
                        address(pool.collateralToken())
                    ),
                    syntheticToken: IMintableBurnableERC20(
                        address(pool.syntheticToken())
                    ),
                    roles: ISynthereumMultiLpLiquidityPool.Roles({
                        admin: roles.admin,
                        maintainer: roles.maintainer
                    }),
                    fee: feePercentage,
                    priceIdentifier: bytes32(bytes(priceIdentifier)),
                    overCollateralRequirement: overCollateralRequirement,
                    liquidationReward: liquidationReward,
                    lendingModuleId: lendingId
                });

        vm.expectRevert("Pool already initialized");
        vm.prank(roles.maintainer);
        pool.initialize(initialisationParams);
        // it should revert with "initializer-disabled"
    }

    function test_GivenSecondAttemptToRe_initialize()
        external
        whenTheProtocolWantsToCreateAPool
        whenPoolIsInitialized
    {
        // it should revert again
    }

    function test_GivenAnUnexpectedFailure()
        external
        whenTheProtocolWantsToCreateAPool
        whenPoolIsInitialized
    {
        // it should revert with fallback error
        // ? it should revert when collateral amount is zero during deployment
        vm.startPrank(roles.maintainer);
        PoolParams memory wrongPoolParams = poolParams;
        wrongPoolParams.overCollateralRequirement = 0;
        vm.expectRevert("Overcollateral requirement must be bigger than 0%");
        deployer.deployPool(poolVersion, abi.encode(wrongPoolParams));
        vm.stopPrank();
    }

    modifier whenLiquidityProviderRegistration() {
        // it should deploy the pool implementation correctly
        vm.prank(roles.maintainer);
        vm.expectEmit(true, false, false, false);
        emit PoolDeployed(1, address(0x000000000000));
        pool = SynthereumMultiLpLiquidityPool(
            address(deployer.deployPool(poolVersion, abi.encode(poolParams)))
        );
        _;
    }

    function test_WhenLiquidityProviderRegistration()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidityProviderRegistration
    {
        // it should allow maintainer to register new LP
        vm.prank(roles.maintainer);
        pool.registerLP(lps[0]);
    }

    function test_GivenSenderIsNotTheMaintainer()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidityProviderRegistration
    {
        // it should revert with "unauthorized"
        vm.expectRevert("Sender must be the maintainer");
        vm.prank(roles.firstWrongAddress);
        pool.registerLP(lps[0]);
    }

    function test_GivenLPIsAlreadyRegistered()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidityProviderRegistration
    {
        vm.startPrank(roles.maintainer);
        pool.registerLP(lps[0]);
        // it should revert with "already-registered"
        vm.expectRevert("LP already registered");
        pool.registerLP(lps[0]);
        vm.stopPrank();
    }

    modifier whenLiquidityProviderActivation() {
        //Register first address before activation
        // vm.prank(roles.maintainer);
        // pool = SynthereumMultiLpLiquidityPool(address(deployer.deployPool(poolVersion, abi.encode(poolParams))));

        vm.prank(roles.maintainer);
        pool.registerLP(lps[0]);

        for (uint8 i = 0; i < lps.length; ++i) {
            deal(collateralAddress, lps[i], 100 ether);
        }
        _;
    }

    //We'll need thoses variables for the rest of the tests
    IERC20 CollateralToken = IERC20(collateralAddress);
    uint256 collateralAmount = 1 ether;
    uint128 overCollateralization = 1 ether;

    function test_WhenLiquidityProviderActivation()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidityProviderActivation
    {
        // it should activate LP when no LPs are active
        vm.startPrank(lps[0]);
        CollateralToken.approve(address(pool), collateralAmount);
        pool.activateLP(collateralAmount, overCollateralization);
        vm.stopPrank();
        // it should activate LP when others are already active
        vm.prank(roles.maintainer);
        pool.registerLP(lps[1]);

        vm.startPrank(lps[1]);
        CollateralToken.approve(address(pool), collateralAmount);
        pool.activateLP(collateralAmount, overCollateralization);
        vm.stopPrank();
    }

    function test_GivenUnregisteredSender()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidityProviderActivation
    {
        // it should revert with "not-registered"
        vm.startPrank(lps[1]);
        CollateralToken.approve(address(pool), collateralAmount);

        vm.expectRevert("Sender must be a registered LP");
        pool.activateLP(collateralAmount, overCollateralization);
        vm.stopPrank();
    }

    function test_GivenCollateralAmountIsZero()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidityProviderActivation
    {
        // it should revert with "zero-collateral"
        vm.startPrank(lps[0]);
        collateralAmount = 0;
        CollateralToken.approve(address(pool), collateralAmount);

        vm.expectRevert("No collateral deposited");
        pool.activateLP(collateralAmount, overCollateralization);
        vm.stopPrank();
    }

    function test_GivenUndercollateralizationAtActivation()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidityProviderActivation
    {
        // it should revert with "insufficient-collateral"
        vm.startPrank(lps[0]);
        overCollateralization = 0.045 ether;
        CollateralToken.approve(address(pool), collateralAmount);

        vm.expectRevert(
            "Overcollateralization must be bigger than overcollateral requirement"
        );
        pool.activateLP(collateralAmount, overCollateralization);
        vm.stopPrank();
    }

    function test_GivenLPAlreadyActiveTriesToActivateAgain()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidityProviderActivation
    {
        // it should revert with "already-active"
        vm.startPrank(lps[0]);
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        pool.activateLP(collateralAmount, overCollateralization);
        vm.expectRevert("LP already active");
        pool.activateLP(collateralAmount, overCollateralization);
        vm.stopPrank();
    }

    function test_GivenQueryingInfoForInactiveLP()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidityProviderActivation
    {
        // it should revert with "inactive-lp"
        vm.prank(roles.randomGuy);
        vm.expectRevert("LP not active");
        pool.positionLPInfo(lps[0]);
    }

    ISynthereumMultiLpLiquidityPool.MintParams mintParams =
        ISynthereumMultiLpLiquidityPool.MintParams({
            minNumTokens: 0,
            collateralAmount: 1 * 10 ** CollateralToken.decimals(),
            expiration: block.timestamp,
            recipient: roles.randomGuy
        });

    modifier whenUserMintTokens() {
        vm.prank(roles.maintainer);
        pool.registerLP(lps[0]);

        for (uint8 i = 0; i < lps.length; ++i) {
            deal(collateralAddress, lps[i], 100 ether);
        }
        vm.prank(lps[0]);
        collateralAmount = 20 ether;
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        vm.prank(lps[0]);
        pool.activateLP(collateralAmount, overCollateralization);
        _;
    }

    function test_WhenUserMintTokens()
        external
        whenTheProtocolWantsToCreateAPool
        whenUserMintTokens
    {
        // it should mint synthetic tokens correctly
        vm.startPrank(roles.randomGuy);
        deal(collateralAddress, roles.randomGuy, 100 ether);
        CollateralToken.approve(address(pool), 1 ether);
        pool.mint(mintParams);
        vm.stopPrank();
        // it should validate all LPs gt minCollateralRatio after mint
        for (uint8 i = 0; i < lps.length; ++i) {
            try pool.positionLPInfo(lps[i]) returns (
                IPoolVault.LPInfo memory lpPosition
            ) {
                assertEq(lpPosition.isOvercollateralized, true);
            } catch {}
        }
    }

    function test_GivenMintTransactionExpired()
        external
        whenTheProtocolWantsToCreateAPool
        whenUserMintTokens
    {
        // it should revert with "expired"
        ISynthereumMultiLpLiquidityPool.MintParams
            memory wrongMintParams = mintParams;
        wrongMintParams.expiration = block.timestamp - 60;

        vm.startPrank(roles.randomGuy);
        deal(collateralAddress, roles.randomGuy, 100 ether);
        CollateralToken.approve(address(pool), 1 ether);
        vm.expectRevert("Transaction expired");
        pool.mint(wrongMintParams);
        vm.stopPrank();
    }

    function test_GivenZeroCollateralSent()
        external
        whenTheProtocolWantsToCreateAPool
        whenUserMintTokens
    {
        // it should revert with "No collateral sent"
        ISynthereumMultiLpLiquidityPool.MintParams
            memory wrongMintParams = mintParams;
        wrongMintParams.collateralAmount = 0;

        vm.startPrank(roles.randomGuy);
        deal(collateralAddress, roles.randomGuy, 100 ether);
        CollateralToken.approve(address(pool), 1 ether);
        vm.expectRevert("No collateral sent");
        pool.mint(wrongMintParams);
        vm.stopPrank();
    }

    function test_GivenTokensReceivedLtMinExpected()
        external
        whenTheProtocolWantsToCreateAPool
        whenUserMintTokens
    {
        // it should revert with "Number of tokens less than minimum limit"
        vm.prank(address(pool));
        uint256 price = priceFeed.getLatestPrice(
            bytes32(bytes(priceIdentifier))
        );

        (, , uint256 tokensAmount) = MultiLpTestHelpers
            .calculateFeeAndSynthAssetForMint(
                feePercentage,
                mintParams.collateralAmount,
                price,
                CollateralToken.decimals(),
                1e18
            );
        ISynthereumMultiLpLiquidityPool.MintParams
            memory wrongMintParams = mintParams;
        wrongMintParams.minNumTokens = tokensAmount;

        vm.startPrank(roles.randomGuy);
        deal(collateralAddress, roles.randomGuy, 100 ether);
        CollateralToken.approve(address(pool), 1 ether);
        vm.expectRevert("Number of tokens less than minimum limit");
        pool.mint(wrongMintParams);
        vm.stopPrank();
    }

    function test_GivenNotEnoughLiquidity()
        external
        whenTheProtocolWantsToCreateAPool
        whenUserMintTokens
    {
        // it should revert with "No enough liquidity for covering mint operation"
        ISynthereumMultiLpLiquidityPool.MintParams
            memory wrongMintParams = mintParams;
        // according 20 USD at 1x leverage in pool :
        wrongMintParams.collateralAmount = 21 ether;
        wrongMintParams.recipient = roles.randomGuy;

        deal(collateralAddress, roles.randomGuy, 100 ether);
        vm.prank(roles.randomGuy);
        CollateralToken.approve(
            address(pool),
            wrongMintParams.collateralAmount
        );
        vm.prank(roles.randomGuy);
        vm.expectRevert("No enough liquidity for covering mint operation");
        pool.mint(wrongMintParams);
    }

    //we need the total minted tokens stored for the following tests:
    uint256 mintedTokens;

    modifier whenUserRedeemTokens() {
        //First lp provide liquidity :
        vm.prank(roles.maintainer);
        pool.registerLP(lps[0]);

        for (uint8 i = 0; i < lps.length; ++i) {
            deal(collateralAddress, lps[i], 100 ether);
        }
        vm.prank(lps[0]);
        collateralAmount = 20 ether;
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        vm.prank(lps[0]);
        pool.activateLP(collateralAmount, overCollateralization);

        //Then, randomGuy mints token
        vm.startPrank(roles.randomGuy);
        deal(collateralAddress, roles.randomGuy, 100 ether);
        CollateralToken.approve(address(pool), 1 ether);
        (mintedTokens, ) = pool.mint(mintParams);
        vm.stopPrank();
        _;
    }

    function test_WhenUserRedeemTokens()
        external
        whenTheProtocolWantsToCreateAPool
        whenUserRedeemTokens
    {
        IERC20 SyntheticToken = IERC20(address(pool.syntheticToken()));
        uint256 userBalance = SyntheticToken.balanceOf(roles.randomGuy);
        // it should redeem tokens correctly
        ISynthereumMultiLpLiquidityPool.RedeemParams memory redeemParams = ISynthereumMultiLpLiquidityPool
            .RedeemParams({
                // it should fully redeem user balance
                numTokens: userBalance,
                minCollateral: 0,
                expiration: block.timestamp,
                recipient: roles.randomGuy
            });

        vm.prank(roles.randomGuy);
        SyntheticToken.approve(address(pool), userBalance);
        vm.prank(roles.randomGuy);
        pool.redeem(redeemParams);
        // it should validate LPs' collateralization after redeem
        for (uint8 i = 0; i < lps.length; ++i) {
            try pool.positionLPInfo(lps[i]) returns (
                IPoolVault.LPInfo memory lpPosition
            ) {
                assertEq(lpPosition.isOvercollateralized, true);
            } catch {}
        }
    }

    function test_GivenRedeemTransactionExpired()
        external
        whenTheProtocolWantsToCreateAPool
        whenUserRedeemTokens
    {
        IERC20 SyntheticToken = IERC20(address(pool.syntheticToken()));
        uint256 userBalance = SyntheticToken.balanceOf(roles.randomGuy);
        ISynthereumMultiLpLiquidityPool.RedeemParams
            memory redeemParams = ISynthereumMultiLpLiquidityPool.RedeemParams({
                numTokens: userBalance,
                minCollateral: 0,
                expiration: block.timestamp,
                recipient: roles.randomGuy
            });
        ISynthereumMultiLpLiquidityPool.RedeemParams
            memory wrongRedeemParams = redeemParams;
        // it should revert with "expired"
        wrongRedeemParams.expiration = block.timestamp - 1;
        vm.prank(roles.randomGuy);
        SyntheticToken.approve(address(pool), userBalance);
        vm.prank(roles.randomGuy);
        vm.expectRevert("Transaction expired");
        pool.redeem(wrongRedeemParams);
    }

    function test_GivenZeroTokensSent()
        external
        whenTheProtocolWantsToCreateAPool
        whenUserRedeemTokens
    {
        IERC20 SyntheticToken = IERC20(address(pool.syntheticToken()));
        uint256 userBalance = SyntheticToken.balanceOf(roles.randomGuy);
        ISynthereumMultiLpLiquidityPool.RedeemParams
            memory redeemParams = ISynthereumMultiLpLiquidityPool.RedeemParams({
                numTokens: userBalance,
                minCollateral: 0,
                expiration: block.timestamp,
                recipient: roles.randomGuy
            });
        ISynthereumMultiLpLiquidityPool.RedeemParams
            memory wrongRedeemParams = redeemParams;
        // it should revert with "zero-amount"
        wrongRedeemParams.numTokens = 0;
        vm.prank(roles.randomGuy);
        SyntheticToken.approve(address(pool), userBalance);
        vm.prank(roles.randomGuy);
        vm.expectRevert("No tokens sent");
        pool.redeem(wrongRedeemParams);
    }

    function test_GivenAmountExceedsPoolBalance()
        external
        whenTheProtocolWantsToCreateAPool
        whenUserRedeemTokens
    {
        IERC20 SyntheticToken = IERC20(address(pool.syntheticToken()));
        uint256 userBalance = SyntheticToken.balanceOf(roles.randomGuy);
        ISynthereumMultiLpLiquidityPool.RedeemParams
            memory redeemParams = ISynthereumMultiLpLiquidityPool.RedeemParams({
                numTokens: userBalance,
                minCollateral: 0,
                expiration: block.timestamp,
                recipient: roles.randomGuy
            });
        ISynthereumMultiLpLiquidityPool.RedeemParams
            memory wrongRedeemParams = redeemParams;

        // Getting current price :
        vm.prank(address(pool));
        uint256 price = priceFeed.getLatestPrice(
            bytes32(bytes(priceIdentifier))
        );

        // it should revert with "Collateral amount less than minimum limit"
        (, , uint256 collAmount) = MultiLpTestHelpers
            .calculateFeeAndCollateralForRedeem(
                feePercentage,
                userBalance,
                price,
                SyntheticToken.decimals(),
                1e18
            );
        wrongRedeemParams.minCollateral = collAmount + 1;
        vm.prank(roles.randomGuy);
        SyntheticToken.approve(address(pool), userBalance);
        vm.prank(roles.randomGuy);
        vm.expectRevert("Collateral amount less than minimum limit");
        pool.redeem(wrongRedeemParams);
    }

    modifier whenLPAddsLiquidity() {
        //First lp provide liquidity :
        vm.prank(roles.maintainer);
        pool.registerLP(lps[0]);

        for (uint8 i = 0; i < lps.length; ++i) {
            deal(collateralAddress, lps[i], 100 ether);
        }
        vm.prank(lps[0]);
        collateralAmount = 20 ether;
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        vm.prank(lps[0]);
        pool.activateLP(collateralAmount, overCollateralization);
        _;
    }

    function test_WhenLPAddsLiquidity()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPAddsLiquidity
    {
        // it should allow active LP to add liquidity
        vm.prank(lps[0]);
        //collateralAmount previously set at 20e18
        pool.addLiquidity(collateralAmount);
    }

    function test_GivenLPIsInactive()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPAddsLiquidity
    {
        // it should revert with "Sender must be an active LP"
        // lps[1] isn't registered yet :
        vm.prank(roles.maintainer);
        pool.registerLP(lps[1]);

        //then lp try to addLiquidity without activation :
        vm.prank(lps[1]);
        CollateralToken.approve(address(pool), collateralAmount);

        vm.prank(lps[1]);
        vm.expectRevert("Sender must be an active LP");
        pool.addLiquidity(collateralAmount);
    }

    function test_GivenNoCollateralSent()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPAddsLiquidity
    {
        // it should revert with "No collateral added"
        collateralAmount = 0;

        vm.prank(lps[0]);
        vm.expectRevert("No collateral added");
        pool.addLiquidity(collateralAmount);
    }

    uint256 collateralDeposited;
    modifier whenLPRemovesLiquidity() {
        //First lp provide liquidity :
        vm.prank(roles.maintainer);
        pool.registerLP(lps[0]);

        for (uint8 i = 0; i < lps.length; ++i) {
            deal(collateralAddress, lps[i], 100 ether);
        }
        vm.prank(lps[0]);
        collateralAmount = 20 ether;
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        vm.prank(lps[0]);
        (collateralDeposited) = pool.activateLP(
            collateralAmount,
            overCollateralization
        );
        _;
    }

    function test_WhenLPRemovesLiquidity()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPRemovesLiquidity
    {
        // it should allow LP to remove liquidity
        vm.prank(lps[0]);
        pool.removeLiquidity(collateralDeposited);
    }

    function test_GivenLPIsNotActive()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPRemovesLiquidity
    {
        // it should revert with "Sender must be an active LP"
        vm.prank(roles.maintainer);
        pool.registerLP(lps[1]);

        vm.prank(lps[1]);
        vm.expectRevert("Sender must be an active LP");
        pool.removeLiquidity(collateralDeposited);
    }

    function test_GivenNoLiquidityToWithdraw()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPRemovesLiquidity
    {
        // it should revert with "nothing-to-withdraw"
        collateralDeposited = 0;
        vm.prank(lps[0]);
        vm.expectRevert("No collateral withdrawn");
        pool.removeLiquidity(collateralDeposited);
    }

    function test_GivenWithdrawalExceedsDeposit()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPRemovesLiquidity
    {
        // it should revert with "exceeds-balance"
        collateralDeposited = 2 * collateralDeposited;
        vm.prank(lps[0]);
        vm.expectRevert("SafeERC20: ERC20 operation did not succeed");
        pool.removeLiquidity(collateralDeposited);
    }

    function test_GivenPost_withdrawCollateralLtMin()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPRemovesLiquidity
    {
        // first a user mints tokens to update minimum collateralization level
        vm.startPrank(roles.randomGuy);
        deal(collateralAddress, roles.randomGuy, 100 ether);
        CollateralToken.approve(address(pool), 1 ether);
        pool.mint(mintParams);
        vm.stopPrank();

        // it should revert with "LP below its overcollateralization level"
        vm.prank(lps[0]);
        vm.expectRevert("LP below its overcollateralization level");
        pool.removeLiquidity(collateralDeposited);
    }

    modifier whenSettingOvercollateralization() {
        //First lp provide liquidity :
        vm.prank(roles.maintainer);
        pool.registerLP(lps[0]);

        for (uint8 i = 0; i < lps.length; ++i) {
            deal(collateralAddress, lps[i], 100 ether);
        }
        vm.prank(lps[0]);
        collateralAmount = 20 ether;
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        vm.prank(lps[0]);
        (collateralDeposited) = pool.activateLP(
            collateralAmount,
            overCollateralization
        );
        _;
    }

    function test_WhenSettingOvercollateralization()
        external
        whenTheProtocolWantsToCreateAPool
        whenSettingOvercollateralization
    {
        // it should allow LP to set overcollateralization
        vm.prank(lps[0]);
        pool.setOvercollateralization(0.25 ether);
    }

    function test_RevertGiven_LPIsNotActivated()
        external
        whenTheProtocolWantsToCreateAPool
        whenSettingOvercollateralization
    {
        //lps[1] is inactive
        vm.prank(lps[1]);
        vm.expectRevert("Sender must be an active LP");
        pool.setOvercollateralization(0.25 ether);

        // it should revert
    }

    function test_RevertGiven_NewOCLtProtocolRequirement()
        external
        whenTheProtocolWantsToCreateAPool
        whenSettingOvercollateralization
    {
        // it should revert if the new overcollateralization below overcollateral
        // overCollateralRequirement = 0.05 ether
        vm.prank(lps[0]);
        vm.expectRevert(
            "Overcollateralization must be bigger than overcollateral requirement"
        );
        pool.setOvercollateralization(0.04 ether);
    }

    function test_RevertGiven_PositionBecomesUndercollateralized()
        external
        whenTheProtocolWantsToCreateAPool
        whenSettingOvercollateralization
    {
        //first we mint tokens to update lp position :
        vm.startPrank(roles.randomGuy);
        deal(collateralAddress, roles.randomGuy, 100 ether);
        CollateralToken.approve(address(pool), 10 ether);
        mintParams.collateralAmount = 10 ether;
        pool.mint(mintParams);
        vm.stopPrank();

        //Then we get the price
        vm.prank(address(pool));
        uint256 price = priceFeed.getLatestPrice(
            bytes32(bytes(priceIdentifier))
        );

        //Then we need actualCollateralAmount & total tokensCollateralized to calculate our below collateralisation level value
        IPoolVault.LPInfo memory lpInfo = pool.positionLPInfo(lps[0]);

        IERC20 SyntheticToken = IERC20(address(pool.syntheticToken()));

        (, , uint256 collAmount) = MultiLpTestHelpers
            .calculateFeeAndCollateralForRedeem(
                0,
                lpInfo.tokensCollateralized,
                price,
                SyntheticToken.decimals(),
                1e18
            );

        uint newOverCollateralization = (1001 *
            ((lpInfo.actualCollateralAmount * 1e18) / collAmount)) / 1000;

        // it should revert with LP below its overcollateralization level
        vm.prank(lps[0]);
        vm.expectRevert("LP below its overcollateralization level");
        pool.setOvercollateralization(uint128(newOverCollateralization));
    }

    modifier whenLiquidation() {
        //First lp provide liquidity :
        vm.prank(roles.maintainer);
        pool.registerLP(lps[0]);

        for (uint8 i = 0; i < lps.length; ++i) {
            deal(collateralAddress, lps[i], 100 ether);
        }
        //First LP provides
        vm.prank(lps[0]);
        collateralAmount = 20 ether;
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        vm.prank(lps[0]);
        pool.activateLP(collateralAmount, overCollateralization);
        //Second LP provides
        vm.prank(roles.maintainer);
        pool.registerLP(lps[1]);
        vm.prank(lps[1]);
        collateralAmount = 10 ether;
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        vm.prank(lps[1]);
        pool.activateLP(collateralAmount, overCollateralization - 0.5 ether);
        _;
    }

    event Liquidated(
        address indexed user,
        address indexed lp,
        uint256 synthTokensInLiquidation,
        uint256 collateralAmount,
        uint256 bonusAmount,
        uint256 collateralReceived
    );

    function test_WhenLiquidation()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidation
    {
        // it should allow liquidation of undercollateralized LP
        // we mint tokens to update lp position :
        deal(collateralAddress, roles.randomGuy, 100 ether);
        vm.prank(roles.randomGuy);
        CollateralToken.approve(address(pool), 40 ether);
        mintParams.collateralAmount = 40 ether;
        vm.prank(roles.randomGuy);
        pool.mint(mintParams);

        //To liquidate we need to get the less collateralized LP :
        (
            address lessCollateralizedLP,
            uint256 coverage,
            uint256 tokens
        ) = MultiLpTestHelpers.getLessCollateralizedLP(pool);

        //Then we get the price
        vm.prank(address(pool));
        uint256 price = priceFeed.getLatestPrice(
            bytes32(bytes(priceIdentifier))
        );

        //Then we need coverage & tokens to calculate our new price to liquidate the less collateralized LP :
        uint256 exceedCollPcg = (coverage * 1e18) /
            (1e18 + overCollateralRequirement);
        //Then we need to increase the price to liquidate the less collateralized LP :
        uint256 newPrice = (101 * ((exceedCollPcg * price) / 1e18)) / 100;

        //Then we set the new oracle price using cheatcodes :
        vm.mockCall(
            address(synthereumChainlinkPriceFeed),
            abi.encodeWithSelector(
                bytes4(keccak256("getLatestPrice(bytes32)")),
                bytes32(bytes(priceIdentifier))
            ),
            abi.encode(uint256(newPrice))
        );

        //We first try to liquidate 1/3 of the tokens of the less collateralized LP :
        uint256 tokensToLiquidate = tokens / 3;

        IERC20 SyntheticToken = IERC20(address(pool.syntheticToken()));
        vm.prank(roles.randomGuy);
        SyntheticToken.approve(address(pool), tokensToLiquidate);

        //We isolate conversionResult & tokensSupply to test liquidation event values
        (, , uint256 conversionResult) = MultiLpTestHelpers
            .calculateFeeAndCollateralForRedeem(
                0,
                tokensToLiquidate,
                newPrice,
                SyntheticToken.decimals(),
                1e18
            );
        uint256 tokensSupply = SyntheticToken.totalSupply();

        vm.expectEmit(true, true, true, false);
        emit Liquidated(
            roles.randomGuy,
            lessCollateralizedLP,
            tokensToLiquidate,
            conversionResult,
            (conversionResult * 5) / 100, // bonus amount (5% of collateral)
            conversionResult + ((conversionResult * 5) / 100) // collateral received
        );
        vm.prank(roles.randomGuy);
        pool.liquidate(lessCollateralizedLP, tokensToLiquidate);


    }

    function test_WhenLiquidationAllLpPosition()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidation
    {
        // it should liquidate all LP position
        // we mint tokens to update lp position :
        deal(collateralAddress, roles.randomGuy, 100 ether);
        vm.prank(roles.randomGuy);
        CollateralToken.approve(address(pool), 40 ether);
        mintParams.collateralAmount = 40 ether;
        vm.prank(roles.randomGuy);
        pool.mint(mintParams);

        //To liquidate we need to get the less collateralized LP :
        (
            address lessCollateralizedLP,
            uint256 coverage,
            uint256 tokens
        ) = MultiLpTestHelpers.getLessCollateralizedLP(pool);

        //Then we get the price
        vm.prank(address(pool));
        uint256 price = priceFeed.getLatestPrice(
            bytes32(bytes(priceIdentifier))
        );

        //Then we need coverage & tokens to calculate our new price to liquidate the less collateralized LP :
        uint256 exceedCollPcg = (coverage * 1e18) /
            (1e18 + overCollateralRequirement);
        //Then we need to increase the price to liquidate the less collateralized LP :
        uint256 newPrice = (101 * ((exceedCollPcg * price) / 1e18)) / 100;

        //Then we set the new oracle price using cheatcodes :
        vm.mockCall(
            address(synthereumChainlinkPriceFeed),
            abi.encodeWithSelector(
                bytes4(keccak256("getLatestPrice(bytes32)")),
                bytes32(bytes(priceIdentifier))
            ),
            abi.encode(uint256(newPrice))
        );

        //We try to liquidate all the tokens of the less collateralized LP :
        uint256 tokensToLiquidate = tokens;

        IERC20 SyntheticToken = IERC20(address(pool.syntheticToken()));
        vm.prank(roles.randomGuy);
        SyntheticToken.approve(address(pool), tokensToLiquidate);

        //We isolate conversionResult & tokensSupply to test liquidation event values
        (, , uint256 conversionResult) = MultiLpTestHelpers
            .calculateFeeAndCollateralForRedeem(
                0,
                tokensToLiquidate,
                newPrice,
                SyntheticToken.decimals(),
                1e18
            );
        uint256 tokensSupply = SyntheticToken.totalSupply();

        vm.expectEmit(true, true, true, false);
        emit Liquidated(
            roles.randomGuy,
            lessCollateralizedLP,
            tokensToLiquidate,
            conversionResult,
            (conversionResult * 5) / 100, // bonus amount (5% of collateral)
            conversionResult + ((conversionResult * 5) / 100) // collateral received
        );
        vm.prank(roles.randomGuy);
        pool.liquidate(lessCollateralizedLP, tokensToLiquidate);

        //We check that the LP position is empty

        IPoolVault.LPInfo memory lpInfoAfterLiquidation = pool.positionLPInfo(lessCollateralizedLP);
        assertEq(lpInfoAfterLiquidation.tokensCollateralized, 0);

    }

    function test_RevertGiven_LPIsUnactive()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidation
    {
        // it should revert if the LP is not active
        address unactiveLP = makeAddr("unactiveLP");
        vm.prank(unactiveLP);
        vm.expectRevert("LP is not active");
        pool.liquidate(unactiveLP, 1);
    }

    function test_RevertGiven_LPIsStillCollateralized()
        external
        whenTheProtocolWantsToCreateAPool
        whenLiquidation
    {
        // it should revert
        vm.prank(roles.randomGuy);
        CollateralToken.approve(address(pool), 10 ether);
        mintParams.collateralAmount = 10 ether;
        deal(collateralAddress, roles.randomGuy, 100 ether);
        vm.prank(roles.randomGuy);
        pool.mint(mintParams);

        vm.prank(roles.randomGuy);
        vm.expectRevert("LP is overcollateralized");
        pool.liquidate(lps[0], 1);
    }

    modifier whenLPProfitsOrLossInterestsAreSplit() {
         //First lp provide liquidity :
        vm.prank(roles.maintainer);
        pool.registerLP(lps[0]);

        for (uint8 i = 0; i < lps.length; ++i) {
            deal(collateralAddress, lps[i], 100 ether);
        }
        //First LP provides
        vm.prank(lps[0]);
        collateralAmount = 100 ether;
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        vm.prank(lps[0]);
        pool.activateLP(collateralAmount, overCollateralization);

        //Second LP provides
        vm.prank(roles.maintainer);
        pool.registerLP(lps[1]);

        vm.prank(lps[1]);
        collateralAmount = 30 ether;
        CollateralToken.approve(address(pool), 2 * collateralAmount);
        vm.prank(lps[1]);
        pool.activateLP(collateralAmount, overCollateralization);

        //then we mint tokens to update lp position :
        deal(collateralAddress, roles.randomGuy, 100 ether);
        vm.prank(roles.randomGuy);
        CollateralToken.approve(address(pool), 30 ether);
        mintParams.collateralAmount = 30 ether;
        vm.prank(roles.randomGuy);
        pool.mint(mintParams);

        

        //Mock the exchange rate to increase it for 7% APY over 30 days
        uint256 initialExchangeRate = 1.04 ether;
        // 7% APY over 30 days = 7% * (30/365) = 0.575% increase
        
        // Mock the lending manager's getAccumulatedInterest
        uint256 poolInterest = 1000 ether;
        uint256 commissionInterest = 100 ether;
        uint256 buybackInterest = 100 ether;
        uint256 totalInterest = poolInterest + commissionInterest + buybackInterest;
        
        //Before we check the accumulated interest, we check the pool position
        pool.positionLPInfo(lps[0]);
        // vm.mockCall(
        // address(lendingManager),
        // abi.encodeWithSelector(ILendingManager.getAccumulatedInterest.selector, pool),
        // abi.encode(poolInterest, commissionInterest, buybackInterest, 0)
        // );

        //Then we assume 30 days have passed
        vm.warp(block.timestamp + 30 days);


        _;
    }

    function test_WhenLPProfitsOrLossInterestsAreSplit()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPProfitsOrLossInterestsAreSplit
    {
        //Then we check the accumulated interest
        uint256 poolInterest = MultiLpTestHelpers.updatePositions(address(pool), finder);
        assertEq(poolInterest, 0);
        pool.positionLPInfo(lps[0]);

        // it should split lending interests correctly
        // it should distribute profits among LPs
        // it should distribute losses among LPs
    }

    function test_RevertGiven_LPsAreUndercapitalized()
        external
        whenTheProtocolWantsToCreateAPool
        whenLPProfitsOrLossInterestsAreSplit
    {
        // it should revert
    }

    modifier whenTransferToLendingManager() {
        _;
    }

    function test_WhenTransferToLendingManager()
        external
        whenTheProtocolWantsToCreateAPool
        whenTransferToLendingManager
    {
        // it should allow transfer to lending manager
    }

    function test_RevertGiven_Non_managerSender()
        external
        whenTheProtocolWantsToCreateAPool
        whenTransferToLendingManager
    {
        // it should revert
    }

    modifier whenTransferPoolParamsAreSetByMaintainer() {
        _;
    }

    function test_WhenTransferPoolParamsAreSetByMaintainer()
        external
        whenTheProtocolWantsToCreateAPool
        whenTransferPoolParamsAreSetByMaintainer
    {
        // it should update liquidation reward
        // it should update mint/burn fee
    }

    function test_RevertGiven_Non_maintainerSender()
        external
        whenTheProtocolWantsToCreateAPool
        whenTransferPoolParamsAreSetByMaintainer
    {
        // it should revert
    }

    function test_RevertGiven_RewardEquals0()
        external
        whenTheProtocolWantsToCreateAPool
        whenTransferPoolParamsAreSetByMaintainer
    {
        // it should revert
    }

    function test_RevertGiven_RewardGt100()
        external
        whenTheProtocolWantsToCreateAPool
        whenTransferPoolParamsAreSetByMaintainer
    {
        // it should revert
    }

    function test_RevertGiven_Non_maintainerSetsFee()
        external
        whenTheProtocolWantsToCreateAPool
        whenTransferPoolParamsAreSetByMaintainer
    {
        // it should revert
    }

    function test_RevertGiven_FeeGte100()
        external
        whenTheProtocolWantsToCreateAPool
        whenTransferPoolParamsAreSetByMaintainer
    {
        // it should revert
    }

    modifier whenStorageMigration() {
        _;
    }

    function test_WhenStorageMigration()
        external
        whenTheProtocolWantsToCreateAPool
        whenStorageMigration
    {
        // it should allow storage migration
    }

    function test_RevertGiven_CallerIsNotLendingManager()
        external
        whenTheProtocolWantsToCreateAPool
        whenStorageMigration
    {
        // it should revert
    }

    modifier whenGettingTradingInfoFromMinting() {
        _;
    }

    function test_WhenGettingTradingInfoFromMinting()
        external
        whenTheProtocolWantsToCreateAPool
        whenGettingTradingInfoFromMinting
    {
        // it should return mint quote
    }

    function test_RevertGiven_ZeroCollateralAmount()
        external
        whenTheProtocolWantsToCreateAPool
        whenGettingTradingInfoFromMinting
    {
        // it should revert
    }

    function test_RevertGiven_InsufficientLiquidity()
        external
        whenTheProtocolWantsToCreateAPool
        whenGettingTradingInfoFromMinting
    {
        // it should revert
    }

    modifier whenGettingTradingInfoFromRedeeming() {
        _;
    }

    function test_WhenGettingTradingInfoFromRedeeming()
        external
        whenTheProtocolWantsToCreateAPool
        whenGettingTradingInfoFromRedeeming
    {
        // it should return redeem quote
    }

    function test_RevertGiven_NoTokenAmountPassed()
        external
        whenTheProtocolWantsToCreateAPool
        whenGettingTradingInfoFromRedeeming
    {
        // it should revert
    }

    function test_RevertGiven_MoreTokensThanAvailable()
        external
        whenTheProtocolWantsToCreateAPool
        whenGettingTradingInfoFromRedeeming
    {
        // it should revert
    }

    modifier whenSwitchingToANewLendingModuleProtocol() {
        _;
    }

    function test_WhenSwitchingToANewLendingModuleProtocol()
        external
        whenTheProtocolWantsToCreateAPool
        whenSwitchingToANewLendingModuleProtocol
    {
        // it should switch to bonus-yield module
        // it should switch to fee-based lending module
    }

    function test_RevertGiven_CallerIsNotManager()
        external
        whenTheProtocolWantsToCreateAPool
        whenSwitchingToANewLendingModuleProtocol
    {
        // it should revert
    }

    function test_RevertGiven_TooManyTokensRequested()
        external
        whenTheProtocolWantsToCreateAPool
        whenSwitchingToANewLendingModuleProtocol
    {
        // it should revert
    }

    function test_WhenUsingLendingModuleWithDepositBonus()
        external
        whenTheProtocolWantsToCreateAPool
    {
        // it should allow mint
        // it should allow redeem
        // it should allow add liquidity
        // it should allow remove liquidity
        // it should allow liquidation
    }

    function test_WhenUsingLendingModuleWithDepositFees()
        external
        whenTheProtocolWantsToCreateAPool
    {
        // it should allow mint
        // it should allow redeem
        // it should allow add liquidity
        // it should allow remove liquidity
        // it should allow liquidation
    }

    modifier whenClaimingLendingRewards() {
        _;
    }

    function test_WhenClaimingLendingRewards()
        external
        whenTheProtocolWantsToCreateAPool
        whenClaimingLendingRewards
    {
        // it should allow claiming rewards
    }

    function test_RevertGiven_CallerIsNotMaintainer()
        external
        whenTheProtocolWantsToCreateAPool
        whenClaimingLendingRewards
    {
        // it should revert
    }

    function test_RevertGiven_InvalidCollateralToken()
        external
        whenTheProtocolWantsToCreateAPool
        whenClaimingLendingRewards
    {
        // it should revert
    }

    function test_RevertGiven_WrongBearingToken()
        external
        whenTheProtocolWantsToCreateAPool
        whenClaimingLendingRewards
    {
        // it should revert
    }

    function test_RevertGiven_CallerNotLendingManager()
        external
        whenTheProtocolWantsToCreateAPool
        whenClaimingLendingRewards
    {
        // it should revert
    }
}
