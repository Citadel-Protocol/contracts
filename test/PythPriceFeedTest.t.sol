// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import "forge-std/Test.sol";
import {SynthereumFinder} from "../src/Finder.sol";
import {SynthereumPriceFeed} from "../src/oracle/PriceFeed.sol";
import {SynthereumPythPriceFeed} from "../src/oracle/implementations/PythPriceFeed.sol";
import {SynthereumPriceFeedImplementation} from "../src/oracle/implementations/PriceFeedImplementation.sol";
import {StandardAccessControlEnumerable} from "../src/roles/StandardAccessControlEnumerable.sol";
import {MockPyth} from "@pythnetwork/pyth-sdk-solidity/MockPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title Pyth Price Feed Test Suite
 * @notice Comprehensive tests for Pyth Network oracle integration
 */
contract PythPriceFeedTest is Test {
    SynthereumFinder public finder;
    SynthereumPriceFeed public priceFeed;
    SynthereumPythPriceFeed public pythPriceFeed;
    MockPyth public mockPyth;
    
    address public admin = address(0x1);
    address public maintainer = address(0x2);
    address public user = address(0x3);
    
    // Test price feed IDs
    bytes32 public constant EUR_USD_ID = bytes32("EURUSD");
    bytes32 public constant BTC_USD_ID = bytes32("BTCUSD");
    
    // Mock Pyth price feed IDs
    bytes32 public constant PYTH_EUR_USD_ID = 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b;
    bytes32 public constant PYTH_BTC_USD_ID = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    
    // Test price data
    int64 public constant EUR_USD_PRICE = 110000000; // 1.1 USD per EUR (8 decimals)
    int64 public constant BTC_USD_PRICE = 4500000000000; // 45,000 USD per BTC (8 decimals)
    uint64 public constant PRICE_CONF = 1000000; // 0.01 confidence (8 decimals)
    int32 public constant PRICE_EXPO = -8; // 8 decimal places
    
    // Use block.timestamp for current time
    function getCurrentTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }
    
    event PriceUpdated(bytes32 indexed priceId, int64 price, uint64 conf, int32 expo, uint256 publishTime);
    
    function setUp() public {
        vm.startPrank(admin);
        
        // Deploy MockPyth
        mockPyth = new MockPyth(60, 1);
        
        // Deploy Finder
        finder = new SynthereumFinder(
            SynthereumFinder.Roles(admin, maintainer)
        );
        
        // Deploy main PriceFeed
        priceFeed = new SynthereumPriceFeed(
            finder,
            StandardAccessControlEnumerable.Roles(admin, maintainer)
        );
        
        // Deploy Pyth PriceFeed implementation
        pythPriceFeed = new SynthereumPythPriceFeed(
            finder,
            address(mockPyth),
            StandardAccessControlEnumerable.Roles(admin, maintainer)
        );
        
        // Switch to maintainer for configuration
        vm.stopPrank();
        vm.startPrank(maintainer);
        
        // Register PriceFeed in Finder
        finder.changeImplementationAddress(bytes32("PriceFeed"), address(priceFeed));
        
        // Register Pyth oracle in main PriceFeed
        priceFeed.addOracle("pyth", address(pythPriceFeed));
        
        vm.stopPrank();
        vm.startPrank(admin);
        
        // Give admin some ETH for price updates
        vm.deal(admin, 10 ether);
        
        // Setup initial price data in MockPyth
        setupMockPriceFeeds();
        
        vm.stopPrank();
    }
    
    function setupMockPriceFeeds() internal {
        // Setup EUR/USD price
        bytes[] memory eurUpdateData = createSinglePriceUpdateData(
            PYTH_EUR_USD_ID,
            EUR_USD_PRICE,
            PRICE_CONF,
            PRICE_EXPO,
            getCurrentTimestamp()
        );
        uint256 eurFee = mockPyth.getUpdateFee(eurUpdateData);
        mockPyth.updatePriceFeeds{value: eurFee}(eurUpdateData);
        
        // Setup BTC/USD price
        bytes[] memory btcUpdateData = createSinglePriceUpdateData(
            PYTH_BTC_USD_ID,
            BTC_USD_PRICE,
            PRICE_CONF,
            PRICE_EXPO,
            getCurrentTimestamp()
        );
        uint256 btcFee = mockPyth.getUpdateFee(btcUpdateData);
        mockPyth.updatePriceFeeds{value: btcFee}(btcUpdateData);
    }
    
    function createSinglePriceUpdateData(
        bytes32 id,
        int64 price,
        uint64 conf,
        int32 expo,
        uint256 publishTime
    ) internal pure returns (bytes[] memory) {
        bytes[] memory updateData = new bytes[](1);
        
        PythStructs.Price memory priceStruct = PythStructs.Price({
            price: price,
            conf: conf,
            expo: expo,
            publishTime: publishTime
        });
        
        PythStructs.PriceFeed memory pythPriceFeedStruct = PythStructs.PriceFeed({
            id: id,
            price: priceStruct,
            emaPrice: priceStruct // Use same price for EMA
        });
        
        updateData[0] = abi.encode(pythPriceFeedStruct);
        return updateData;
    }
    
    function testDeployment() public {
        assertTrue(address(pythPriceFeed) != address(0));
        assertTrue(address(mockPyth) != address(0));
        assertEq(address(pythPriceFeed.pyth()), address(mockPyth));
        assertEq(address(pythPriceFeed.synthereumFinder()), address(finder));
    }
    
    function testSetPairSuccess() public {
        vm.startPrank(maintainer);
        
        // Setup EUR/USD pair
        pythPriceFeed.setPair(
            "EURUSD",
            SynthereumPriceFeedImplementation.Type.NORMAL,
            address(mockPyth),
            0,
            abi.encode(PYTH_EUR_USD_ID),
            0
        );
        
        // Verify pair was set
        assertTrue(pythPriceFeed.isPriceSupported(EUR_USD_ID));
        
        vm.stopPrank();
    }
    
    function testSetPairInvalidSource() public {
        vm.startPrank(maintainer);
        
        vm.expectRevert("Source must be Pyth contract address");
        pythPriceFeed.setPair(
            "EURUSD",
            SynthereumPriceFeedImplementation.Type.NORMAL,
            address(0x123), // Wrong address
            0,
            abi.encode(PYTH_EUR_USD_ID),
            0
        );
        
        vm.stopPrank();
    }
    
    function testSetPairInvalidExtraData() public {
        vm.startPrank(maintainer);
        
        vm.expectRevert("Extra data must be 32 bytes (Pyth price feed ID)");
        pythPriceFeed.setPair(
            "EURUSD",
            SynthereumPriceFeedImplementation.Type.NORMAL,
            address(mockPyth),
            0,
            abi.encode(uint256(123)), // Wrong length
            0
        );
        
        vm.stopPrank();
    }
    
    function testGetLatestPrice() public {
        vm.startPrank(maintainer);
        
        // Setup EUR/USD pair
        pythPriceFeed.setPair(
            "EURUSD",
            SynthereumPriceFeedImplementation.Type.NORMAL,
            address(mockPyth),
            0,
            abi.encode(PYTH_EUR_USD_ID),
            0
        );
        
        vm.stopPrank();
        
        // Test getting latest price (off-chain call)
        vm.startPrank(user, user); // Make tx.origin == msg.sender
        
        uint256 price = pythPriceFeed.getLatestPrice(string("EURUSD"));
        
        // Expected: 1.1 * 10^18 (scaled to 18 decimals from 8 decimals)
        uint256 expectedPrice = uint256(uint64(EUR_USD_PRICE)) * 10**(18-8);
        assertEq(price, expectedPrice);
        
        vm.stopPrank();
    }
    
    function testGetLatestPriceWithConversion() public {
        vm.startPrank(maintainer);
        
        // Setup EUR/USD pair with conversion (e.g., multiply by 1.05)
        uint256 conversionUnit = 1.05 ether;
        pythPriceFeed.setPair(
            "EURUSD",
            SynthereumPriceFeedImplementation.Type.NORMAL,
            address(mockPyth),
            conversionUnit,
            abi.encode(PYTH_EUR_USD_ID),
            0
        );
        
        vm.stopPrank();
        
        vm.startPrank(user, user);
        
        uint256 price = pythPriceFeed.getLatestPrice(string("EURUSD"));
        
        // Expected: (1.1 * 10^18) / 1.05
        uint256 basePrice = uint256(uint64(EUR_USD_PRICE)) * 10**(18-8);
        uint256 expectedPrice = basePrice * 1e18 / conversionUnit;
        assertEq(price, expectedPrice);
        
        vm.stopPrank();
    }
    
    function testGetLatestPriceReverse() public {
        vm.startPrank(maintainer);
        
        // Setup USD/EUR pair (reverse of EUR/USD)
        pythPriceFeed.setPair(
            "USDEUR",
            SynthereumPriceFeedImplementation.Type.REVERSE,
            address(mockPyth),
            0,
            abi.encode(PYTH_EUR_USD_ID),
            0
        );
        
        vm.stopPrank();
        
        vm.startPrank(user, user);
        
        uint256 price = pythPriceFeed.getLatestPrice(string("USDEUR"));
        
        // Expected: 1 / (1.1 * 10^18) * 10^36
        uint256 basePrice = uint256(uint64(EUR_USD_PRICE)) * 10**(18-8);
        uint256 expectedPrice = (10**36) / basePrice;
        assertEq(price, expectedPrice);
        
        vm.stopPrank();
    }
    
    function testUpdatePriceFeeds() public {
        // Create price update data
        bytes[] memory updateData = createSinglePriceUpdateData(
            PYTH_BTC_USD_ID,
            5000000000000, // 50,000 USD per BTC
            PRICE_CONF,
            PRICE_EXPO,
            block.timestamp
        );
        
        // Get update fee
        uint256 fee = pythPriceFeed.getUpdateFee(updateData);
        
        // Update price feeds
        vm.deal(user, fee + 1 ether);
        vm.startPrank(user);
        
        uint256 balanceBefore = user.balance;
        pythPriceFeed.updatePriceFeeds{value: fee + 0.1 ether}(updateData);
        uint256 balanceAfter = user.balance;
        
        // Check that excess was refunded
        assertEq(balanceAfter, balanceBefore - fee);
        
        vm.stopPrank();
    }
    
    function testUpdatePriceFeedsInsufficientFee() public {
        bytes[] memory updateData = createSinglePriceUpdateData(
            PYTH_BTC_USD_ID,
            5000000000000,
            PRICE_CONF,
            PRICE_EXPO,
            block.timestamp
        );
        
        uint256 fee = pythPriceFeed.getUpdateFee(updateData);
        
        vm.deal(user, fee - 1);
        vm.startPrank(user);
        
        vm.expectRevert("Insufficient fee for price update");
        pythPriceFeed.updatePriceFeeds{value: fee - 1}(updateData);
        
        vm.stopPrank();
    }
    
    function testGetPythPrice() public {
        PythStructs.Price memory price = pythPriceFeed.getPythPrice(PYTH_EUR_USD_ID);
        
        assertEq(price.price, EUR_USD_PRICE);
        assertEq(price.conf, PRICE_CONF);
        assertEq(price.expo, PRICE_EXPO);
        // Check that publish time is recent (within last 60 seconds)
        assertTrue(price.publishTime >= block.timestamp - 60);
    }
    
    function testGetDynamicMaxSpread() public {
        vm.startPrank(maintainer);
        
        // Setup pair with dynamic spread (maxSpread = 0)
        pythPriceFeed.setPair(
            "EURUSD",
            SynthereumPriceFeedImplementation.Type.NORMAL,
            address(mockPyth),
            0,
            abi.encode(PYTH_EUR_USD_ID),
            0 // Dynamic spread
        );
        
        uint64 spread = pythPriceFeed.getMaxSpread(string("EURUSD"));
        
        // Calculate expected spread: (conf * 2) / price
        uint256 expectedSpread = (uint256(PRICE_CONF) * 2 * 1e18) / uint256(uint64(EUR_USD_PRICE));
        assertEq(spread, expectedSpread);
        
        vm.stopPrank();
    }
    
    function testEmergencyWithdraw() public {
        // Send some ETH to the contract
        vm.deal(address(pythPriceFeed), 1 ether);
        
        vm.startPrank(admin);
        
        uint256 balanceBefore = admin.balance;
        pythPriceFeed.emergencyWithdraw(payable(admin), 0.5 ether);
        uint256 balanceAfter = admin.balance;
        
        assertEq(balanceAfter - balanceBefore, 0.5 ether);
        assertEq(address(pythPriceFeed).balance, 0.5 ether);
        
        vm.stopPrank();
    }
    
    function testEmergencyWithdrawUnauthorized() public {
        vm.deal(address(pythPriceFeed), 1 ether);
        
        vm.startPrank(user);
        
        vm.expectRevert();
        pythPriceFeed.emergencyWithdraw(payable(user), 0.5 ether);
        
        vm.stopPrank();
    }
    
    function testIntegrationWithMainPriceFeed() public {
        vm.startPrank(maintainer);
        
        // Setup EUR/USD pair in Pyth implementation
        pythPriceFeed.setPair(
            "EURUSD",
            SynthereumPriceFeedImplementation.Type.NORMAL,
            address(mockPyth),
            0,
            abi.encode(PYTH_EUR_USD_ID),
            0
        );
        
        // Setup EUR/USD pair in main price feed
        string[] memory emptyArray;
        priceFeed.setPair(
            "EURUSD",
            SynthereumPriceFeed.Type.STANDARD,
            "pyth",
            emptyArray
        );
        
        vm.stopPrank();
        
        // Test price retrieval through main price feed
        vm.startPrank(user, user);
        
        uint256 price = priceFeed.getLatestPrice(string("EURUSD"));
        uint256 expectedPrice = uint256(uint64(EUR_USD_PRICE)) * 10**(18-8);
        assertEq(price, expectedPrice);
        
        // Test price support check
        assertTrue(priceFeed.isPriceSupported(EUR_USD_ID));
        
        vm.stopPrank();
    }
    
    function testNegativePriceHandling() public {
        vm.startPrank(maintainer);
        
        pythPriceFeed.setPair(
            "TESTNEG",
            SynthereumPriceFeedImplementation.Type.NORMAL,
            address(mockPyth),
            0,
            abi.encode(PYTH_EUR_USD_ID),
            0
        );
        
        // Update with negative price
        bytes[] memory updateData = createSinglePriceUpdateData(
            PYTH_EUR_USD_ID,
            -1000000, // Negative price
            PRICE_CONF,
            PRICE_EXPO,
            block.timestamp
        );
        
        mockPyth.updatePriceFeeds(updateData);
        
        vm.stopPrank();
        
        vm.startPrank(user, user);
        
        vm.expectRevert("Negative price not supported");
        pythPriceFeed.getLatestPrice(string("TESTNEG"));
        
        vm.stopPrank();
    }
    
    function testReceiveETH() public {
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        
        (bool success,) = address(pythPriceFeed).call{value: 0.5 ether}("");
        assertTrue(success);
        assertEq(address(pythPriceFeed).balance, 0.5 ether);
        
        vm.stopPrank();
    }
}