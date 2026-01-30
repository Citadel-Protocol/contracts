// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import "forge-std/Script.sol";
import {SynthereumVaultFactory} from "../../src/multiLP-vaults/VaultFactory.sol";
import {SynthereumVault} from "../../src/multiLP-vaults/Vault.sol";
import {SynthereumPublicVaultRegistry} from "../../src/registries/PublicVaultRegistry.sol";
import {SynthereumFinder} from "../../src/Finder.sol";
import {ISynthereumFinder} from "../../src/interfaces/IFinder.sol";
import {SynthereumInterfaces} from "../../src/Constants.sol";

contract DeployVaultFactory is Script {
    
    function getFinderAddress() internal view returns (address) {
        string memory finderData = vm.readFile("script/deployments/addresses/finder.txt");
        return vm.parseAddress(vm.split(finderData, "=")[1]);
    }
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        address finderAddress = getFinderAddress();
        
        // Deploy Vault Implementation
        SynthereumVault vaultImplementation = new SynthereumVault();
        
        // Deploy VaultFactory
        SynthereumVaultFactory vaultFactory = new SynthereumVaultFactory(
            finderAddress,
            address(vaultImplementation)
        );
        
        // Deploy PublicVaultRegistry
        SynthereumPublicVaultRegistry vaultRegistry = new SynthereumPublicVaultRegistry(
            ISynthereumFinder(finderAddress)
        );
        
        // Register both in Finder
        SynthereumFinder finder = SynthereumFinder(finderAddress);
        finder.changeImplementationAddress(
            SynthereumInterfaces.VaultFactory,
            address(vaultFactory)
        );
        finder.changeImplementationAddress(
            SynthereumInterfaces.VaultRegistry,
            address(vaultRegistry)
        );
        
        vm.stopBroadcast();
        
        // Write deployed addresses to files
        string memory vaultImplData = string(abi.encodePacked(
            "VAULT_IMPLEMENTATION_ADDRESS=", vm.toString(address(vaultImplementation))
        ));
        vm.writeFile("script/deployments/addresses/vaultImplementation.txt", vaultImplData);
        
        string memory vaultFactoryData = string(abi.encodePacked(
            "VAULT_FACTORY_ADDRESS=", vm.toString(address(vaultFactory))
        ));
        vm.writeFile("script/deployments/addresses/vaultFactory.txt", vaultFactoryData);
        
        string memory vaultRegistryData = string(abi.encodePacked(
            "VAULT_REGISTRY_ADDRESS=", vm.toString(address(vaultRegistry))
        ));
        vm.writeFile("script/deployments/addresses/vaultRegistry.txt", vaultRegistryData);
        
        console.log("=== Vault Factory System Deployed ===");
        console.log("Vault Implementation:", address(vaultImplementation));
        console.log("Vault Factory:", address(vaultFactory));
        console.log("Vault Registry:", address(vaultRegistry));
        console.log("Registered in Finder:", finderAddress);
    }
}