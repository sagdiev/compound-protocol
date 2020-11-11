pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "./CErc20.sol";
import "./CToken.sol";
import "./PriceOracle.sol";
import "./Exponential.sol";
import "./BEP20Interface.sol";

interface V1PriceOracleInterface {
    function assetPrices(address asset) external view returns (uint);
}

interface IStdReference {
    /// A structure returned whenever someone requests for standard reference data.
    struct ReferenceData {
        uint256 rate; // base/quote exchange rate, multiplied by 1e18.
        uint256 lastUpdatedBase; // UNIX epoch of the last time when base price gets updated.
        uint256 lastUpdatedQuote; // UNIX epoch of the last time when quote price gets updated.
    }

    /// Returns the price data for the given base/quote pair. Revert if not available.
    function getReferenceData(string calldata _base, string calldata _quote)
        external
        view
        returns (ReferenceData memory);

    /// Similar to getReferenceData, but with multiple base/quote pairs at once.
    function getRefenceDataBulk(string[] calldata _bases, string[] calldata _quotes)
        external
        view
        returns (ReferenceData[] memory);
}

contract PriceOracleProxyBSC is PriceOracle, Exponential {
    /**
     * @dev Possible error codes that we can return for BAND oracle
     */
    enum OracleError {
        NO_ERROR,
        ERR_INVALID,
        ERR_REVERTED
    }

    /// @notice Admin address that could set the underlying symbol of crTokens
    address public admin;

    /// @notice Indicator that this is a PriceOracle contract (for inspection)
    bool public constant isPriceOracle = true;

    /// @notice Quote symbol we used for BAND reference contract
    string public constant QUOTE_SYMBOL = "BNB";

    /// @notice The v1 price oracle, which will continue to serve prices for v1 assets
    V1PriceOracleInterface public v1PriceOracle;

    /// @notice The BAND oracle contract
    IStdReference public ref;

    /// @notice The mapping records the crToken and its underlying symbol that we use for BAND reference
    ///         It's not necessarily equals to the symbol in the underlying contract
    mapping(address => string) public underlyingSymbols;

    /// @notice crBNB address that has a constant price of 1e18
    address public cBnbAddress;

    /**
     * @param admin_ The address of admin to set underlying symbols for BAND oracle
     * @param v1PriceOracle_ The address of the v1 price oracle, which will continue to operate and hold prices for collateral assets
     * @param reference_ The price reference contract, which will be served for our primary price source on BSC
     * @param cBnbAddress_ The address of cBNB, which will return a constant 1e18, since all prices relative to bnb
     */
    constructor(address admin_,
                address v1PriceOracle_,
                address reference_,
                address cBnbAddress_) public {
        admin = admin_;
        v1PriceOracle = V1PriceOracleInterface(v1PriceOracle_);
        ref = IStdReference(reference_);
        cBnbAddress = cBnbAddress_;
    }

    /**
     * @notice Get the underlying price of a listed cToken asset
     * @param cToken The cToken to get the underlying price of
     * @return The underlying asset price mantissa (scaled by 1e18)
     */
    function getUnderlyingPrice(CToken cToken) public view returns (uint) {
        address cTokenAddress = address(cToken);

        if (cTokenAddress == cBnbAddress) {
            // bnb always worth 1
            return 1e18;
        }

        bytes memory symbol = bytes(underlyingSymbols[cTokenAddress]);
        if (symbol.length != 0) {
            OracleError oracleErr;
            Exp memory price;
            (oracleErr, price) = getPriceFromBAND(string(symbol));
            if (oracleErr != OracleError.NO_ERROR) {
                // Fallback to v1 PriceOracle
                return getPriceFromV1(cTokenAddress);
            }

            MathError mathErr;
            uint underlyingDecimals;
            underlyingDecimals = BEP20Interface(CErc20(cTokenAddress).underlying()).decimals();
            (mathErr, price) = mulScalar(price, 10**(18 - underlyingDecimals));
            if (mathErr != MathError.NO_ERROR) {
                // Fallback to v1 PriceOracle
                return getPriceFromV1(cTokenAddress);
            }

            return price.mantissa;
        }

        return getPriceFromV1(cTokenAddress);
    }

    function getPriceFromBAND(string memory symbol) internal view returns (OracleError, Exp memory) {
        (bool success, bytes memory returnData) =
            address(ref).staticcall(
                abi.encodePacked(
                    ref.getReferenceData.selector,
                    abi.encode(symbol, QUOTE_SYMBOL)
                )
            );
        if (success) {
            IStdReference.ReferenceData memory data = abi.decode(returnData, (IStdReference.ReferenceData));
            if (data.rate == 0) {
                return (OracleError.ERR_INVALID, Exp({mantissa: 0}));
            }
            return (OracleError.NO_ERROR, Exp({mantissa: data.rate}));
        }
        return (OracleError.ERR_REVERTED, Exp({mantissa: 0}));
    }

    function getPriceFromV1(address cTokenAddress) internal view returns (uint) {
        address underlying = CErc20(cTokenAddress).underlying();
        return v1PriceOracle.assetPrices(underlying);
    }

    function _setAdmin(address _admin) external {
        require(msg.sender == admin, "!admin");
        admin = _admin;
    }

    function _setUnderlyingSymbols(address[] calldata cTokenAddresses, string[] calldata symbols) external {
        require(msg.sender == admin, "!admin");
        for (uint i = 0; i < cTokenAddresses.length; i++) {
            underlyingSymbols[cTokenAddresses[i]] = symbols[i];
        }
    }
}
