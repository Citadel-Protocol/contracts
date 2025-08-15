// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import "forge-std/Test.sol";

import {SynthereumFinder} from "../src/Finder.sol";
import {SynthereumDeployer} from "../src/Deployer.sol";
import {StandardAccessControlEnumerable} from "../src/roles/StandardAccessControlEnumerable.sol";
import {SynthereumPriceFeed} from "../src/oracle/PriceFeed.sol";
import {SynthereumManager} from "../src/Manager.sol";
import {SynthereumCollateralWhitelist} from "../src/CollateralWhitelist.sol";
import {SynthereumIdentifierWhitelist} from "../src/IdentifierWhitelist.sol";
import {SynthereumFactoryVersioning} from "../src/FactoryVersioning.sol";
import {SynthereumTrustedForwarder} from "../src/TrustedForwarder.sol";
import {SynthereumChainlinkPriceFeed} from "../src/oracle/implementations/ChainlinkPriceFeed.sol";
import {SynthereumPriceFeedImplementation} from "../src/oracle/implementations/PriceFeedImplementation.sol";
import {SynthereumSyntheticTokenPermitFactory} from "../src/tokens/factories/SyntheticTokenPermitFactory.sol";
import {SynthereumMultiLpLiquidityPoolFactory} from "../src/pool/MultiLpLiquidityPoolFactory.sol";
import {SynthereumMultiLpLiquidityPool} from "../src/pool/MultiLpLiquidityPool.sol";
import {LendingStorageManager} from "../src/lending-module/LendingStorageManager.sol";
import {LendingManager} from "../src/lending-module/LendingManager.sol";
import {ILendingStorageManager} from "../src/lending-module/interfaces/ILendingStorageManager.sol";
import {ILendingManager} from "../src/lending-module/interfaces/ILendingManager.sol";
import {SynthereumPoolRegistry} from "../src/registries/PoolRegistry.sol";
import {SynthereumPublicVaultRegistry} from "../src/registries/PublicVaultRegistry.sol";
import {SynthereumVaultFactory} from "../src/multiLP-vaults/VaultFactory.sol";
import {SynthereumVault} from "../src/multiLP-vaults/Vault.sol";
import {IVault} from "../src/multiLP-vaults/interfaces/IVault.sol";

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";
import {ISynthereumMultiLpLiquidityPool} from "../src/pool/interfaces/IMultiLpLiquidityPool.sol";
import {IStandardERC20} from "../src/base/interfaces/IStandardERC20.sol";
import {IMintableBurnableERC20} from "../src/tokens/interfaces/IMintableBurnableERC20.sol";
import {CompoundModule} from "../src/lending-module/lending-modules/Compound.sol";
import {ICompoundToken} from "../src/interfaces/ICToken.sol";

contract VaultDepositScenariosTest is Test {
    struct Roles {
        address admin;
        address maintainer;
        address[] liquidityProviders;
        address minter;
        address dao;
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

    // Test constants
    address public constant FDUSD_ADDRESS = 0xc5f0f7b66764F6ec8C8Dff7BA683102295E16409;
    address public constant DEBT_TOKEN_ADDRESS = 0xC4eF4229FEc74Ccfe17B2bdeF7715fAC740BA0ba;
    address public constant CHAINLINK_AGGREGATOR = 0x0bf79F617988C472DcA68ff41eFe1338955b9A80;
    
    string public constant PRICE_IDENTIFIER = "EURUSD";
    string public constant SYNTHETIC_NAME = "Citadel Euro";
    string public constant SYNTHETIC_SYMBOL = "cEUR";
    string public constant LENDING_ID = "Compound";
    
    // Pool configuration with 0% jrtBuybackShare as requested
    uint64 public constant DAO_INTEREST_SHARE = 0.1 ether; // 10%
    uint64 public constant JRT_BUYBACK_SHARE = 0; // 0% as requested
    uint64 public constant FEE_PERCENTAGE = 0.002 ether; // 0.2%
    uint128 public constant OVER_COLLATERAL_REQUIREMENT = 0.05 ether; // 5%
    uint64 public constant LIQUIDATION_REWARD = 0.5 ether; // 50%
    uint64 public constant MAX_SPREAD = 0.001 ether; // 0.1%
    
    // Test amount
    uint256 public constant DEPOSIT_AMOUNT = 100 ether; // 100 FDUSD

    // Contract instances
    SynthereumFinder finder;
    SynthereumDeployer deployer;
    SynthereumPriceFeed priceFeed;
    SynthereumChainlinkPriceFeed chainlinkPriceFeed;
    SynthereumManager manager;
    SynthereumCollateralWhitelist collateralWhitelist;
    SynthereumIdentifierWhitelist identifierWhitelist;
    SynthereumSyntheticTokenPermitFactory tokenFactory;
    SynthereumPoolRegistry poolRegistry;
    SynthereumPublicVaultRegistry vaultRegistry;
    SynthereumFactoryVersioning factoryVersioning;
    SynthereumTrustedForwarder trustedForwarder;
    LendingStorageManager lendingStorageManager;
    LendingManager lendingManager;
    CompoundModule compoundModule;
    SynthereumMultiLpLiquidityPoolFactory poolFactory;
    SynthereumVaultFactory vaultFactory;
    
    SynthereumMultiLpLiquidityPool pool;
    IERC20 synthToken;
    IERC20 collateralToken;
    
    // Vaults with different leverage levels
    IVault vault1x;  // Conservative (1x leverage)
    IVault vault5x;  // Moderate (5x leverage) 
    IVault vault20x; // Aggressive (20x leverage)

    address[] lps;
    Roles public roles = Roles({
    admin : makeAddr("admin"),
    maintainer: makeAddr("maintainer"),
    minter : makeAddr("minter"),
        // Setup test roles
    dao : makeAddr("dao"),
    liquidityProviders : lps
    });
        

    function setUp() public {
        roles.liquidityProviders.push(makeAddr("firstLP"));
        roles.liquidityProviders.push(makeAddr("secondLP"));
        lps.push(makeAddr("secondLP"));
        // Deploy all infrastructure contracts
        vm.startPrank(roles.maintainer);
        
        // 1. Deploy Finder
        finder = new SynthereumFinder(
            SynthereumFinder.Roles(roles.admin, roles.maintainer)
        );
        
        // 2. Deploy Price Feed system
        priceFeed = new SynthereumPriceFeed(
            finder,
            StandardAccessControlEnumerable.Roles(roles.admin, roles.maintainer)
        );
        
        chainlinkPriceFeed = new SynthereumChainlinkPriceFeed(
            finder,
            StandardAccessControlEnumerable.Roles(roles.admin, roles.maintainer)
        );
        
        finder.changeImplementationAddress(
            bytes32(bytes("PriceFeed")),
            address(priceFeed)
        );
        
        priceFeed.addOracle("chainlink", address(chainlinkPriceFeed));
        
        chainlinkPriceFeed.setPair(
            PRICE_IDENTIFIER,
            SynthereumPriceFeedImplementation.Type(1),
            CHAINLINK_AGGREGATOR,
            0,
            "",
            MAX_SPREAD
        );
        
        string[] memory emptyArray;
        priceFeed.setPair(
            PRICE_IDENTIFIER,
            SynthereumPriceFeed.Type(1),
            "chainlink",
            emptyArray
        );
        
        // 3. Deploy Whitelists
        collateralWhitelist = new SynthereumCollateralWhitelist(
            SynthereumCollateralWhitelist.Roles(roles.admin, roles.maintainer)
        );
        collateralWhitelist.addToWhitelist(FDUSD_ADDRESS);
        finder.changeImplementationAddress(
            bytes32(bytes("CollateralWhitelist")),
            address(collateralWhitelist)
        );
        
        identifierWhitelist = new SynthereumIdentifierWhitelist(
            SynthereumIdentifierWhitelist.Roles(roles.admin, roles.maintainer)
        );
        identifierWhitelist.addToWhitelist(bytes32(bytes(PRICE_IDENTIFIER)));
        finder.changeImplementationAddress(
            bytes32(bytes("IdentifierWhitelist")),
            address(identifierWhitelist)
        );
        
        // 4. Deploy Token Factory
        tokenFactory = new SynthereumSyntheticTokenPermitFactory(
            address(finder)
        );
        finder.changeImplementationAddress(
            bytes32(bytes("TokenFactory")),
            address(tokenFactory)
        );
        
        // 5. Deploy Lending Infrastructure
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
        
        compoundModule = new CompoundModule();

        lendingManager.setLendingModule(
            LENDING_ID,
            ILendingStorageManager.LendingInfo(address(compoundModule), "")
        );
        
        // 6. Deploy Registries
        poolRegistry = new SynthereumPoolRegistry(finder);
        finder.changeImplementationAddress(
            bytes32(bytes("PoolRegistry")),
            address(poolRegistry)
        );
        
        vaultRegistry = new SynthereumPublicVaultRegistry(finder);
        finder.changeImplementationAddress(
            bytes32(bytes("VaultRegistry")),
            address(vaultRegistry)
        );
        
        // 7. Deploy Manager
        manager = new SynthereumManager(
            finder,
            SynthereumManager.Roles(roles.admin, roles.maintainer)
        );
        finder.changeImplementationAddress(
            bytes32(bytes("Manager")),
            address(manager)
        );
        
        // 8. Deploy Factory Versioning
        factoryVersioning = new SynthereumFactoryVersioning(
            SynthereumFactoryVersioning.Roles(roles.admin, roles.maintainer)
        );
        finder.changeImplementationAddress(
            bytes32(bytes("FactoryVersioning")),
            address(factoryVersioning)
        );
        
        // 9. Deploy Trusted Forwarder
        trustedForwarder = new SynthereumTrustedForwarder();
        finder.changeImplementationAddress(
            bytes32(bytes("TrustedForwarder")),
            address(trustedForwarder)
        );

        SynthereumMultiLpLiquidityPool poolImplementation = new SynthereumMultiLpLiquidityPool();

        
        // 10. Deploy Pool Factory
        poolFactory = new SynthereumMultiLpLiquidityPoolFactory(
            address(finder),
            address(poolImplementation)
        );
        // Register the pool factory in FactoryVersioning for the correct version
        factoryVersioning.setFactory(
            bytes32(bytes("PoolFactory")),
            1,
            address(poolFactory)
        );
        
        // 11. Deploy Vault Factory
        SynthereumVault vaultImplementation = new SynthereumVault();
        vaultFactory = new SynthereumVaultFactory(
            address(finder),
            address(vaultImplementation)
        );
        finder.changeImplementationAddress(
            bytes32(bytes("VaultFactory")),
            address(vaultFactory)
        );
        
        // 12. Deploy Deployer
        deployer = new SynthereumDeployer(
            finder,
            SynthereumDeployer.Roles(roles.admin, roles.maintainer)
        );
        finder.changeImplementationAddress(
            bytes32(bytes("Deployer")),
            address(deployer)
        );
        
        // 13. Deploy Pool
        LendingManagerParams memory lendingParams = LendingManagerParams(
            LENDING_ID,
            DEBT_TOKEN_ADDRESS,
            DAO_INTEREST_SHARE,
            JRT_BUYBACK_SHARE
        );
        
        PoolParams memory poolParams = PoolParams(
            1, // version
            FDUSD_ADDRESS,
            SYNTHETIC_NAME,
            SYNTHETIC_SYMBOL,
            address(0),
            StandardAccessControlEnumerable.Roles(roles.admin, roles.maintainer),
            FEE_PERCENTAGE,
            bytes32(bytes(PRICE_IDENTIFIER)),
            OVER_COLLATERAL_REQUIREMENT,
            LIQUIDATION_REWARD,
            lendingParams
        );
        
        pool = SynthereumMultiLpLiquidityPool(
            address(deployer.deployPool(1, abi.encode(poolParams)))
        );
        
        synthToken = IERC20(address(pool.syntheticToken()));
        collateralToken = IERC20(FDUSD_ADDRESS);
        
        // 14. Deploy Vaults with different leverage levels
        // 1x leverage = 200% overcollateralization (2.0 ether)
        vault1x = deployer.deployPublicVault(
            "Citadel Vault Conservative",
            "cVAULT-1X",
            address(pool),
            2.0 ether
        );
        
        // 5x leverage = 120% overcollateralization (1.2 ether)
        vault5x = deployer.deployPublicVault(
            "Citadel Vault Moderate", 
            "cVAULT-5X",
            address(pool),
            1.2 ether
        );
        
        // 20x leverage = 105% overcollateralization (1.05 ether)
        vault20x = deployer.deployPublicVault(
            "Citadel Vault Aggressive",
            "cVAULT-20X", 
            address(pool),
            1.05 ether
        );
        
        // Register vaults as LPs in the pool
        pool.registerLP(address(vault1x));
        pool.registerLP(address(vault5x));
        pool.registerLP(address(vault20x));
        
        vm.stopPrank();
        
        // Fund test accounts with FDUSD
        deal(FDUSD_ADDRESS, roles.minter, 1000 ether);
        deal(FDUSD_ADDRESS, roles.liquidityProviders[0], 10000 ether);
        deal(FDUSD_ADDRESS, roles.liquidityProviders[1], 10000 ether);
    }

    function test_VaultDepositScenarios_100FDUSD() public {
        console.log("=== Vault Deposit Scenarios with 100 FDUSD ===");
        console.log("Pool configuration:");
        console.log("- DAO Interest Share: 10%");
        console.log("- JRT Buyback Share: 0% (as requested)");
        console.log("- Fee Percentage: 0.2%");
        console.log("- Over Collateral Requirement: 5%");
        console.log("");
        
        // First, register and provide initial liquidity to the pool
        vm.startPrank(roles.maintainer);
        pool.registerLP(roles.liquidityProviders[0]);
        vm.stopPrank();
        
        vm.startPrank(roles.liquidityProviders[0]);
        collateralToken.approve(address(pool), 5000 ether);
        pool.activateLP(5000 ether, 1.05 ether); // Provide 5000 FDUSD liquidity
        vm.stopPrank();
        
        // Test scenarios for different vault leverage levels
        _testVaultDeposit(vault1x, "1x (Conservative)", DEPOSIT_AMOUNT);
        _testVaultDeposit(vault5x, "5x (Moderate)", DEPOSIT_AMOUNT);
        _testVaultDeposit(vault20x, "20x (Aggressive)", DEPOSIT_AMOUNT);
    }
    
    function _testVaultDeposit(IVault vault, string memory vaultName, uint256 depositAmount) internal {
        console.log("--- %s Vault ---", vaultName);
        
        // Setup
        vm.startPrank(roles.minter);
        collateralToken.approve(address(vault), depositAmount);
        
        // Get initial state
        uint256 initialSynthBalance = synthToken.balanceOf(roles.minter);
        uint256 initialCollateralBalance = collateralToken.balanceOf(roles.minter);
        
        // Make deposit
        uint256 lpTokensReceived = vault.deposit(depositAmount, roles.minter);
        
        // Get final state
        uint256 finalSynthBalance = synthToken.balanceOf(roles.minter);
        uint256 finalCollateralBalance = collateralToken.balanceOf(roles.minter);
        
        // Calculate results
        uint256 synthMinted = finalSynthBalance - initialSynthBalance;
        uint256 collateralSpent = initialCollateralBalance - finalCollateralBalance;
        
        console.log("Deposited: %s FDUSD", _formatAmount(collateralSpent));
        console.log("LP Tokens Received: %s", _formatAmount(lpTokensReceived));
        console.log("Citadel Euros Mintable: %s cEUR", _formatAmount(synthMinted));
        
        // Calculate effective leverage
        if (synthMinted > 0) {
            uint256 leverage = (synthMinted * 1e18) / collateralSpent;
            console.log("Effective Leverage: %s.%sx", leverage / 1e18, (leverage % 1e18) / 1e17);
        }
        
        console.log("");
        vm.stopPrank();
    }
    
    function _formatAmount(uint256 amount) internal pure returns (string memory) {
        return vm.toString(amount / 1e18);
    }
    
    function test_CompareVaultLeverageEfficiency() public {
        console.log("=== Vault Leverage Efficiency Comparison ===");
        
        // Register and provide initial liquidity
        vm.startPrank(roles.maintainer);
        pool.registerLP(roles.liquidityProviders[0]);
        vm.stopPrank();
        
        vm.startPrank(roles.liquidityProviders[0]);
        collateralToken.approve(address(pool), 10000 ether);
        pool.activateLP(10000 ether, 1.05 ether);
        vm.stopPrank();
        
        uint256[3] memory leverages;
        uint256[3] memory synthAmounts;
        
        // Test each vault
        IVault[3] memory vaults = [vault1x, vault5x, vault20x];
        string[3] memory names = ["1x", "5x", "20x"];
        
        for (uint i = 0; i < 3; i++) {
            vm.startPrank(roles.minter);
            collateralToken.approve(address(vaults[i]), DEPOSIT_AMOUNT);
            
            uint256 initialSynth = synthToken.balanceOf(roles.minter);
            vaults[i].deposit(DEPOSIT_AMOUNT, roles.minter);
            uint256 finalSynth = synthToken.balanceOf(roles.minter);
            
            synthAmounts[i] = finalSynth - initialSynth;
            leverages[i] = (synthAmounts[i] * 1e18) / DEPOSIT_AMOUNT;
            
            vm.stopPrank();
        }
        
        console.log("Results for 100 FDUSD deposit:");
        for (uint i = 0; i < 3; i++) {
            // console.log("%s Vault: %s cEUR (Leverage: %s.%sx)", 
            //     names[i], 
            //     _formatAmount(synthAmounts[i]),
            //     leverages[i] / 1e18,
            //     (leverages[i] % 1e18) / 1e17
            // );
            console.log("Vault : ", names[i]);
            console.log("cEUR amount : ", _formatAmount(synthAmounts[i]));
            console.log("leverage : ", leverages[i] / 1e18);
            console.log("virgule : ", (leverages[i] % 1e18) / 1e17);
        }
    }
}