#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

// Configuration
const ADDRESSES_DIR = './script/deployments/addresses';
const OUTPUT_DIR = './deployments';
const OUTPUT_FILE = path.join(OUTPUT_DIR, 'mainnet-addresses.json');

// Ensure output directory exists
if (!fs.existsSync(OUTPUT_DIR)) {
    fs.mkdirSync(OUTPUT_DIR, { recursive: true });
}

// Read all address files and consolidate
const addresses = {};
const timestamp = new Date().toISOString();

try {
    // Read all .txt files in addresses directory
    const files = fs.readdirSync(ADDRESSES_DIR).filter(file => file.endsWith('.txt'));
    
    for (const file of files) {
        const filePath = path.join(ADDRESSES_DIR, file);
        const content = fs.readFileSync(filePath, 'utf8').trim();
        
        // Parse the KEY=VALUE format
        const [key, value] = content.split('=');
        if (key && value) {
            // Convert filename to camelCase key
            const contractName = file.replace('.txt', '');
            addresses[contractName] = {
                address: value,
                key: key
            };
        }
    }
    
    // Create final JSON structure
    const deploymentData = {
        network: 'mainnet',
        chainId: null, // Will be filled by deployment script
        deployedAt: timestamp,
        contracts: addresses
    };
    
    // Write consolidated JSON
    fs.writeFileSync(OUTPUT_FILE, JSON.stringify(deploymentData, null, 2));
    
    console.log(`✅ Addresses consolidated to: ${OUTPUT_FILE}`);
    console.log(`📦 Found ${Object.keys(addresses).length} contracts`);
    
    // Display summary
    console.log('\n📋 Contract Summary:');
    Object.entries(addresses).forEach(([name, data]) => {
        console.log(`  ${name}: ${data.address}`);
    });
    
} catch (error) {
    console.error('❌ Error consolidating addresses:', error.message);
    process.exit(1);
}