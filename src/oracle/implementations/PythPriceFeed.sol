// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.9;

import {ISynthereumFinder} from '../../interfaces/IFinder.sol';
import {IPyth} from '@pythnetwork/pyth-sdk-solidity/IPyth.sol';
import {PythStructs} from '@pythnetwork/pyth-sdk-solidity/PythStructs.sol';
import {SynthereumPriceFeedImplementation} from './PriceFeedImplementation.sol';

/**
 * @title Pyth Network implementation for synthereum price-feed
 * @notice This contract integrates with Pyth Network oracles to provide price feeds
 */
contract SynthereumPythPriceFeed is SynthereumPriceFeedImplementation {
  //----------------------------------------
  // Storage
  //----------------------------------------
  IPyth public immutable pyth;
  
  // Maximum age in seconds for price updates (default: 60 seconds)
  uint256 public constant MAX_PRICE_AGE = 60;

  //----------------------------------------
  // Events
  //----------------------------------------
  event PriceUpdated(bytes32 indexed priceId, int64 price, uint64 conf, int32 expo, uint256 publishTime);

  //----------------------------------------
  // Constructor
  //----------------------------------------
  /**
   * @notice Constructs the SynthereumPythPriceFeed contract
   * @param _synthereumFinder Synthereum finder contract
   * @param _pythContract Pyth contract address
   * @param _roles Admin and Maintainer roles
   */
  constructor(
    ISynthereumFinder _synthereumFinder,
    address _pythContract,
    Roles memory _roles
  ) SynthereumPriceFeedImplementation(_synthereumFinder, _roles) {
    require(_pythContract != address(0), 'Invalid Pyth contract address');
    pyth = IPyth(_pythContract);
  }

  //----------------------------------------
  // External functions
  //----------------------------------------
  /**
   * @notice Add support for a Pyth price feed pair
   * @notice Only maintainer can call this function
   * @param _priceId Name of the pair identifier
   * @param _kind Type of the pair (standard or reversed)
   * @param _source Not used for Pyth (set to pyth contract address)
   * @param _conversionUnit Conversion factor to be applied on price (if 0 no conversion)
   * @param _extraData Pyth price feed ID (bytes32)
   * @param _maxSpread Maximum spread allowed (if 0, dynamic spread calculation)
   */
  function setPair(
    string calldata _priceId,
    Type _kind,
    address _source,
    uint256 _conversionUnit,
    bytes calldata _extraData,
    uint64 _maxSpread
  ) public override {
    require(_extraData.length == 32, 'Extra data must be 32 bytes (Pyth price feed ID)');
    require(_source == address(pyth), 'Source must be Pyth contract address');
    
    super.setPair(
      _priceId,
      _kind,
      _source,
      _conversionUnit,
      _extraData,
      _maxSpread
    );
  }

  /**
   * @notice Update Pyth price feeds with new data
   * @param _priceUpdates Array of price update data from Pyth
   */
  function updatePriceFeeds(bytes[] calldata _priceUpdates) external payable {
    uint256 updateFee = pyth.getUpdateFee(_priceUpdates);
    require(msg.value >= updateFee, 'Insufficient fee for price update');
    
    pyth.updatePriceFeeds{value: updateFee}(_priceUpdates);
    
    // Refund excess payment
    if (msg.value > updateFee) {
      payable(msg.sender).transfer(msg.value - updateFee);
    }
  }

  /**
   * @notice Get the required fee for updating price feeds
   * @param _priceUpdates Array of price update data
   * @return fee Required fee in wei
   */
  function getUpdateFee(bytes[] calldata _priceUpdates) external view returns (uint256 fee) {
    return pyth.getUpdateFee(_priceUpdates);
  }

  /**
   * @notice Get price data without updating (for view calls)
   * @param _pythPriceId Pyth price feed ID
   * @return price Pyth price structure
   */
  function getPythPrice(bytes32 _pythPriceId) external view returns (PythStructs.Price memory price) {
    return pyth.getPriceNoOlderThan(_pythPriceId, MAX_PRICE_AGE);
  }

  //----------------------------------------
  // Internal view functions
  //----------------------------------------
  /**
   * @notice Get latest Pyth oracle price for an input price feed ID
   * @param _priceId HexName of price identifier (not used for Pyth)
   * @param _source Pyth contract address (must match immutable pyth)
   * @param _extraData Pyth price feed ID (bytes32)
   * @return price Price from the Pyth oracle
   * @return decimals Decimals of the price (Pyth uses fixed decimals based on expo)
   */
  function _getOracleLatestRoundPrice(
    bytes32 _priceId,
    address _source,
    bytes memory _extraData
  ) internal view override returns (uint256 price, uint8 decimals) {
    require(_source == address(pyth), 'Invalid source for Pyth price feed');
    require(_extraData.length == 32, 'Invalid extra data length');
    
    // Extract Pyth price feed ID from extra data
    bytes32 pythPriceId;
    assembly {
      pythPriceId := mload(add(_extraData, 32))
    }
    
    // Get price from Pyth (will revert if price is too old)
    PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(pythPriceId, MAX_PRICE_AGE);
    
    // Pyth prices can be negative, but we don't support negative prices
    require(pythPrice.price >= 0, 'Negative price not supported');
    
    // Convert Pyth price to uint256
    price = uint256(uint64(pythPrice.price));
    
    // Calculate decimals from Pyth exponent
    // Pyth exponent is typically negative (e.g., -8 means 8 decimal places)
    require(pythPrice.expo <= 0, 'Positive exponent not supported');
    decimals = uint8(uint32(-pythPrice.expo));
  }

  /**
   * @notice Get dynamic max spread based on Pyth confidence interval
   * @param _priceId HexName of price identifier (not used for Pyth)
   * @param _source Pyth contract address
   * @param _extraData Pyth price feed ID (bytes32)
   * @return maxSpread Dynamic max spread based on confidence
   */
  function _getDynamicMaxSpread(
    bytes32 _priceId,
    address _source,
    bytes memory _extraData
  ) internal view override returns (uint64 maxSpread) {
    require(_source == address(pyth), 'Invalid source for Pyth price feed');
    require(_extraData.length == 32, 'Invalid extra data length');
    
    // Extract Pyth price feed ID from extra data
    bytes32 pythPriceId;
    assembly {
      pythPriceId := mload(add(_extraData, 32))
    }
    
    // Get price from Pyth
    PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(pythPriceId, MAX_PRICE_AGE);
    
    // Calculate spread based on confidence interval
    // Spread = confidence / price * 2 (to account for both directions)
    // Cap at 5% maximum spread
    if (pythPrice.price > 0) {
      uint256 spread = (uint256(pythPrice.conf) * 2e18) / uint256(uint64(pythPrice.price));
      uint256 maxAllowedSpread = 5e16; // 5%
      maxSpread = uint64(spread > maxAllowedSpread ? maxAllowedSpread : spread);
    } else {
      maxSpread = uint64(5e16); // Default to 5% if price is 0
    }
  }

  //----------------------------------------
  // Emergency functions
  //----------------------------------------
  /**
   * @notice Emergency function to withdraw ETH (only admin)
   * @param _to Address to send ETH to
   * @param _amount Amount of ETH to withdraw
   */
  function emergencyWithdraw(address payable _to, uint256 _amount) external {
    require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), 'Sender must be admin');
    require(_to != address(0), 'Invalid recipient address');
    require(_amount <= address(this).balance, 'Insufficient balance');
    _to.transfer(_amount);
  }

  /**
   * @notice Allow contract to receive ETH for price update fees
   */
  receive() external payable {}
}