// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import "forge-std/Script.sol";
import {SynthereumDeployer} from "../../src/Deployer.sol";
import {IVault} from "../../src/multiLP-vaults/interfaces/IVault.sol";

contract DeployVaults is Script {
    
    function getPoolAddress() internal view returns (address) {
        string memory poolData = vm.readFile("script/deployments/addresses/pool.txt");
        return vm.parseAddress(vm.split(poolData, "=")[1]);
    }
    
    function getDeployerAddress() internal view returns (address) {
        string memory deployerData = vm.readFile("script/deployments/addresses/deployer.txt");
        return vm.parseAddress(vm.split(deployerData, "=")[1]);
    }
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        address poolAddress = getPoolAddress();
        address deployerAddress = getDeployerAddress();
        
        // Get deployer contract to create vaults
        SynthereumDeployer deployer = SynthereumDeployer(deployerAddress);
        
        // Deploy Vault 1: Conservative (1x leverage)
        // 1x leverage = 100% collateral required = 1.0 ether overcollateralization
        IVault vault1x = deployer.deployPublicVault(
            "Citadel Vault Conservative",
            "cVAULT-1X",
            poolAddress,
            1.0 ether // 100% overcollateralization for 1x leverage
        );
        
        // Deploy Vault 2: Moderate (5x leverage)
        // 5x leverage = 20% collateral required = 0.2 ether overcollateralization
        IVault vault5x = deployer.deployPublicVault(
            "Citadel Vault Moderate",
            "cVAULT-5X", 
            poolAddress,
            0.2 ether // 20% overcollateralization for 5x leverage
        );
        
        // Deploy Vault 3: Aggressive (20x leverage)
        // 20x leverage = 5% collateral required = 0.05 ether overcollateralization
        IVault vault20x = deployer.deployPublicVault(
            "Citadel Vault Aggressive",
            "cVAULT-20X",
            poolAddress,
            0.05 ether // 5% overcollateralization for 20x leverage
        );
        
        vm.stopBroadcast();
        
        // Write deployed addresses to files
        string memory vault1xData = string(abi.encodePacked(
            "VAULT_1X_ADDRESS=", vm.toString(address(vault1x))
        ));
        vm.writeFile("script/deployments/addresses/vault_1x.txt", vault1xData);
        
        string memory vault5xData = string(abi.encodePacked(
            "VAULT_5X_ADDRESS=", vm.toString(address(vault5x))
        ));
        vm.writeFile("script/deployments/addresses/vault_5x.txt", vault5xData);
        
        string memory vault20xData = string(abi.encodePacked(
            "VAULT_20X_ADDRESS=", vm.toString(address(vault20x))
        ));
        vm.writeFile("script/deployments/addresses/vault_20x.txt", vault20xData);
        
        // // Also write all addresses to a single file for convenience
        // string memory allVaultsData = string(abi.encodePacked(
        //     "VAULT_1X_ADDRESS=", vm.toString(address(vault1x)), "\n",
        //     "VAULT_5X_ADDRESS=", vm.toString(address(vault5x)), "\n", 
        //     "VAULT_20X_ADDRESS=", vm.toString(address(vault20x))
        // ));
        // vm.writeFile("script/deployments/addresses/all_vaults.txt", allVaultsData);
        
        console.log("=== Citadel Vaults Deployed ===");
        console.log("Conservative Vault (1x):", address(vault1x));
        console.log("Moderate Vault (5x):", address(vault5x));
        console.log("Aggressive Vault (20x):", address(vault20x));
        console.log("Pool Address:", poolAddress);
    }
}