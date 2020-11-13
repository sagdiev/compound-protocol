const {
  etherMantissa
} = require('./Utils/Ethereum');

const {
  makeCToken,
  makePriceOracle,
  makeBandReference,
} = require('./Utils/Compound');

describe('PriceOracleProxyBSC', () => {
  let root, accounts;
  let oracle, backingOracle, bandReference, cEth, cOther;
  const baseSymbol = "BNB";

  beforeEach(async () => {
    [root, ...accounts] = saddle.accounts;
    cEth = await makeCToken({kind: "cether", comptrollerOpts: {kind: "v1-no-proxy"}, supportMarket: true});
    cOther = await makeCToken({comptroller: cEth.comptroller, supportMarket: true});

    backingOracle = await makePriceOracle();
    bandReference = await makeBandReference();
    oracle = await deploy('PriceOracleProxyBSC',
      [
        root,
        backingOracle._address,
        bandReference._address,
        cEth._address,
      ]
     );
  });

  describe("constructor", () => {
    it("sets address of admin", async () => {
      let configuredGuardian = await call(oracle, "admin");
      expect(configuredGuardian).toEqual(root);
    });

    it("sets address of v1 oracle", async () => {
      let configuredOracle = await call(oracle, "v1PriceOracle");
      expect(configuredOracle).toEqual(backingOracle._address);
    });

    it("sets address of band reference", async () => {
      let reference = await call(oracle, "ref");
      expect(reference).toEqual(bandReference._address);
    });

    it("sets address of cEth", async () => {
      let configuredCEther = await call(oracle, "cBnbAddress");
      expect(configuredCEther).toEqual(cEth._address);
    });
  });

  describe("getUnderlyingPrice", () => {
    let setAndVerifyBandPrice = async (symbol, price, lastUpdatedBase, lastUpdatedQuote) => {
      await send(
        bandReference,
        "setReferenceData",
        [symbol, etherMantissa(price), lastUpdatedBase, lastUpdatedQuote]);

      let bandReferencePrice = await call(
        bandReference,
        "getReferenceData",
        [symbol, baseSymbol]);

      expect(Number(bandReferencePrice.rate)).toEqual(price * 1e18);
    };

    let setAndVerifyBackingPrice = async (cToken, price) => {
      await send(
        backingOracle,
        "setUnderlyingPrice",
        [cToken._address, etherMantissa(price)]);

      let backingOraclePrice = await call(
        backingOracle,
        "assetPrices",
        [cToken.underlying._address]);

      expect(Number(backingOraclePrice)).toEqual(price * 1e18);
    };

    let readAndVerifyProxyPrice = async (token, price) =>{
      let proxyPrice = await call(oracle, "getUnderlyingPrice", [token._address]);
      expect(Number(proxyPrice)).toEqual(price * 1e18);
    };

    it("always returns 1e18 for crBNB", async () => {
      await readAndVerifyProxyPrice(cEth, 1);
    });

    it('gets price from band reference', async () => {
      const underlyingSymbol = "OTHER";
      const dateTime = Date.now();
      const timestamp = Math.floor(dateTime / 1000);
      await setAndVerifyBandPrice(underlyingSymbol, 15, timestamp, timestamp);
      await setAndVerifyBackingPrice(cOther, 12);

      // Band not support yet.
      await readAndVerifyProxyPrice(cOther, 12);

      await send(oracle, "_setUnderlyingSymbols", [[cOther._address], [underlyingSymbol]]);

      // Get price from Band reference.
      await readAndVerifyProxyPrice(cOther, 15);

      await send(oracle, "_setUnderlyingSymbols", [[cOther._address], [""]]);

      // Fallback to price oracle v1.
      await readAndVerifyProxyPrice(cOther, 12);
    })

    it("proxies for whitelisted tokens", async () => {
      await setAndVerifyBackingPrice(cOther, 11);
      await readAndVerifyProxyPrice(cOther, 11);

      await setAndVerifyBackingPrice(cOther, 37);
      await readAndVerifyProxyPrice(cOther, 37);
    });

    it("returns 0 for token without a price", async () => {
      let unlistedToken = await makeCToken({comptroller: cEth.comptroller});

      await readAndVerifyProxyPrice(unlistedToken, 0);
    });
  });
});
