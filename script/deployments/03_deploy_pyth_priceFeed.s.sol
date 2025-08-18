// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import "forge-std/Script.sol";
import {SynthereumFinder} from "../../src/Finder.sol";
import {SynthereumPriceFeed} from "../../src/oracle/PriceFeed.sol";
import {SynthereumPythPriceFeed} from "../../src/oracle/implementations/PythPriceFeed.sol";
import {SynthereumPriceFeedImplementation} from "../../src/oracle/implementations/PriceFeedImplementation.sol";
import {StandardAccessControlEnumerable} from "../../src/roles/StandardAccessControlEnumerable.sol";

/**
 * @title Deploy Pyth Price Feed Script
 * @notice Deploys and configures Pyth Network oracle integration for Citadel Finance
 */
contract DeployPythPriceFeed is Script {
    // Pyth Network contract addresses for different networks
    // Ethereum Mainnet: 0x4305FB66699C3B2702D4d05CF36551390A4c69C6
    // BSC Mainnet: 0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594
    // BSC Testnet: 0x5744Cbf430D99456a0A8771208b674F27f8EF0Fb
    address constant PYTH_CONTRACT = 0x5744Cbf430D99456a0A8771208b674F27f8EF0Fb; // BSC Testnet
    
    // Pyth price feed IDs (these are fixed IDs from Pyth Network)
    // EUR/USD: 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b
    // BTC/USD: 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
    // ETH/USD: 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
    bytes32 constant EUR_USD_PRICE_ID = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    bytes32 constant BTC_USD_PRICE_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant ETH_USD_PRICE_ID = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    
    // Price identifiers for Citadel Finance
    string constant EUR_USD_IDENTIFIER = "EURUSD";
    string constant BTC_USD_IDENTIFIER = "BTCUSD";
    string constant ETH_USD_IDENTIFIER = "ETHUSD";
    
    // Default max spread for price feeds (0.5%)
    uint64 constant DEFAULT_MAX_SPREAD = 0.005 ether;
    
    function getFinderAddress() internal view returns (address) {
        string memory finderData = vm.readFile("script/deployments/addresses/finder.txt");
        return vm.parseAddress(vm.split(finderData, "=")[1]);
    }
    
    function getPriceFeedAddress() internal view returns (address) {
        string memory priceFeedData = vm.readFile("script/deployments/addresses/priceFeed.txt");
        return vm.parseAddress(vm.split(priceFeedData, "=")[1]);
    }
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(deployerPrivateKey);
        
        console.log("Deploying Pyth Price Feed integration...");
        console.log("Admin address:", admin);
        console.log("Pyth contract:", PYTH_CONTRACT);
        
        vm.startBroadcast(deployerPrivateKey);
        
        SynthereumFinder finder = SynthereumFinder(getFinderAddress());
        SynthereumPriceFeed priceFeed = SynthereumPriceFeed(getPriceFeedAddress());
        
        // Deploy Pyth price feed implementation
        SynthereumPythPriceFeed pythPriceFeed = new SynthereumPythPriceFeed(
            finder,
            PYTH_CONTRACT,
            StandardAccessControlEnumerable.Roles(admin, admin)
        );
        
        console.log("PythPriceFeed deployed at:", address(pythPriceFeed));
        
        // Register Pyth oracle in the main price feed
        priceFeed.addOracle("pyth", address(pythPriceFeed));
        console.log("Pyth oracle registered in main price feed");
        
        // Setup EUR/USD pair
        setupPythPair(
            pythPriceFeed,
            priceFeed,
            EUR_USD_IDENTIFIER,
            EUR_USD_PRICE_ID,
            "EUR/USD pair configured"
        );
        
        // Setup BTC/USD pair
        setupPythPair(
            pythPriceFeed,
            priceFeed,
            BTC_USD_IDENTIFIER,
            BTC_USD_PRICE_ID,
            "BTC/USD pair configured"
        );
        
        // Setup ETH/USD pair
        setupPythPair(
            pythPriceFeed,
            priceFeed,
            ETH_USD_IDENTIFIER,
            ETH_USD_PRICE_ID,
            "ETH/USD pair configured"
        );
        
        vm.stopBroadcast();
        
        // Write deployed addresses to files
        string memory pythData = string(abi.encodePacked(
            "PYTHPRICEFEED_ADDRESS=", vm.toString(address(pythPriceFeed))
        ));
        vm.writeFile("script/deployments/addresses/pythPriceFeed.txt", pythData);
        
        console.log("=== Deployment Summary ===");
        console.log("Pyth Price Feed:", address(pythPriceFeed));
        console.log("Configured pairs: EUR/USD, BTC/USD, ETH/USD");
        console.log("Max spread:", DEFAULT_MAX_SPREAD);
        console.log("Pyth contract:", PYTH_CONTRACT);
        console.log("=========================");
    }
    
    /**
     * @notice Helper function to setup a Pyth price pair
     * @param pythPriceFeed The Pyth price feed implementation
     * @param priceFeed The main price feed contract
     * @param identifier The price identifier string
     * @param pythPriceId The Pyth network price feed ID
     * @param logMessage Message to log on success
     */
    function setupPythPair(
        SynthereumPythPriceFeed pythPriceFeed,
        SynthereumPriceFeed priceFeed,
        string memory identifier,
        bytes32 pythPriceId,
        string memory logMessage
    ) internal {
        // Setup pair in Pyth price feed implementation
        pythPriceFeed.setPair(
            identifier,
            SynthereumPriceFeedImplementation.Type.NORMAL,
            PYTH_CONTRACT,
            0, // No conversion unit
            abi.encode(pythPriceId), // Pyth price feed ID as extra data
            0 // Use dynamic spread based on Pyth confidence
        );
        
        // Setup pair in main price feed
        string[] memory emptyArray;
        priceFeed.setPair(
            identifier,
            SynthereumPriceFeed.Type.STANDARD,
            "pyth",
            emptyArray
        );
        
        console.log(logMessage);
    }
}