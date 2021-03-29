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

// Ref: https://github.com/Uniswap/uniswap-v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
interface IUniswapV2Pair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);

    function symbol() external pure returns (string memory);

    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint);

    function balanceOf(address owner) external view returns (uint);

    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);

    function transfer(address to, uint value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint value
    ) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint);

    function permit(
        address owner,
        address spender,
        uint value,
        uint deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);

    function factory() external view returns (address);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );

    function price0CumulativeLast() external view returns (uint);

    function price1CumulativeLast() external view returns (uint);

    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);

    function burn(address to) external returns (uint amount0, uint amount1);

    function swap(
        uint amount0Out,
        uint amount1Out,
        address to,
        bytes calldata data
    ) external;

    function skim(address to) external;

    function sync() external;

    function initialize(address, address) external;
}

contract PriceOracleProxyBSC is PriceOracle, Exponential {
    /// @notice Admin address
    address public admin;

    /// @notice Guardian address
    address public guardian;

    /// @notice Indicator that this is a PriceOracle contract (for inspection)
    bool public constant isPriceOracle = true;

    /// @notice Quote symbol we used for BAND reference contract
    string public constant QUOTE_SYMBOL = "BNB";

    /// @notice The v1 price oracle, which will continue to serve prices for v1 assets
    V1PriceOracleInterface public v1PriceOracle;

    /// @notice The BAND oracle contract
    IStdReference public ref;

    /// @notice The mapping records the token address and its symbol that is used by BAND reference
    ///         It's not necessarily equals to the token symbol defined in their contract.
    ///         For example, we use symbol BTC for BTCB when it comes to BAND refernce, not BTCB.
    mapping(address => string) public symbols;

    /// @notice Check if the underlying address is Pancakeswap LP
    mapping(address => bool) public areUnderlyingLPs;

    /// @notice crBNB address that has a constant price of 1e18
    address public cBnbAddress;

    address public constant wbnbAddress = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

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

        address underlying = CErc20(cTokenAddress).underlying();
        if (areUnderlyingLPs[cTokenAddress]) {
            return getLPFairPrice(underlying);
        }

        return getTokenPrice(underlying);
    }

    /*** Internal fucntions ***/

    /**
     * @notice Get the price of a specific token.
     * @param token The token to get the price of
     * @return The price
     */
    function getTokenPrice(address token) internal view returns (uint) {
        if (token == wbnbAddress) {
            // wbnb always worth 1
            return 1e18;
        }

        bytes memory symbol = bytes(symbols[token]);
        if (symbol.length != 0) {
            IStdReference.ReferenceData memory data = ref.getReferenceData(string(symbol), QUOTE_SYMBOL);
            uint underlyingDecimals = BEP20Interface(token).decimals();
            return mul_(data.rate, 10**(18 - underlyingDecimals));
        }
        return getPriceFromV1(token);
    }

    /**
     * @notice Get the fair price of a LP. We use the mechanism from Alpha Finance.
     *         Ref: https://blog.alphafinance.io/fair-lp-token-pricing/
     * @param pair The pair of AMM (Pancakeswap)
     * @return The price
     */
    function getLPFairPrice(address pair) internal view returns (uint) {
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();
        uint totalSupply = IUniswapV2Pair(pair).totalSupply();
        (uint r0, uint r1, ) = IUniswapV2Pair(pair).getReserves();
        uint sqrtR = sqrt(mul_(r0, r1));
        uint p0 = getTokenPrice(token0);
        uint p1 = getTokenPrice(token1);
        uint sqrtP = sqrt(mul_(p0, p1));
        return div_(mul_(2, mul_(sqrtR, sqrtP)), totalSupply);
    }

    /**
     * @notice Get price from v1 price oracle
     * @param token The token to get the price of
     * @return The price
     */
    function getPriceFromV1(address token) internal view returns (uint) {
        return v1PriceOracle.assetPrices(token);
    }

    /*** Admin functions ***/

    event SetAdmin(address admin);
    event SetGuardian(address guardian);
    event IsLPUpdated(address tokenAddress, bool isLP);
    event SymbolUpdated(address tokenAddress, string symbol);

    /**
     * @notice Set admin for price oracle proxy
     * @param _admin The new admin
     */
    function _setAdmin(address _admin) external {
        require(msg.sender == admin, "only the admin may set new admin");
        admin = _admin;
        emit SetAdmin(admin);
    }

    /**
     * @notice Set guardian for price oracle proxy
     * @param _guardian The new guardian
     */
    function _setGuardian(address _guardian) external {
        require(msg.sender == admin, "only the admin may set new guardian");
        guardian = _guardian;
        emit SetGuardian(guardian);
    }

    /**
     * @notice Set if a list of cToken are Pancakeswap LP or not.
     * @param _cTokenAddresses The list of cToken address
     * @param _isLP They are LPs or not
     */
    function _setLPs(address[] calldata _cTokenAddresses, bool[] calldata _isLP) external {
        require(msg.sender == admin, "only the admin may set LPs");
        require(_cTokenAddresses.length == _isLP.length, "mismatched data");
        for (uint i = 0; i < _cTokenAddresses.length; i++) {
            areUnderlyingLPs[_cTokenAddresses[i]] = _isLP[i];
            emit IsLPUpdated(_cTokenAddresses[i], _isLP[i]);
        }
    }

    /**
     * @notice Set the token's symbol for BAND reference. If the symbol of a token is set, the price oracle will get its price from BAND protocol.
     * @param _tokenAddresses The list of token address
     * @param _symbols The list of symbols for BAND reference
     */
    function _setSymbols(address[] calldata _tokenAddresses, string[] calldata _symbols) external {
        require(msg.sender == admin || msg.sender == guardian, "only the admin or guardian may set symbols");
        require(_tokenAddresses.length == _symbols.length, "mismatched data");
        for (uint i = 0; i < _tokenAddresses.length; i++) {
            if (bytes(_symbols[i]).length != 0) {
                require(msg.sender == admin, "guardian may only clear the symbol");
            }
            symbols[_tokenAddresses[i]] = _symbols[i];
            emit SymbolUpdated(_tokenAddresses[i], _symbols[i]);
        }
    }
}
