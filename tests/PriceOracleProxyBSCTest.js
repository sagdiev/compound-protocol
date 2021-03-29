const {
  etherMantissa
} = require('./Utils/Ethereum');

const {
  makeToken,
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

    it("sets address of cBNB", async () => {
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

      await send(oracle, "_setSymbols", [[cOther.underlying._address], [underlyingSymbol]]);

      // Get price from Band reference.
      await readAndVerifyProxyPrice(cOther, 15);

      await send(oracle, "_setSymbols", [[cOther.underlying._address], [""]]);

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

  describe("_setAdmin", () => {
    it("set admin successfully", async () => {
      expect(await send(oracle, "_setAdmin", [accounts[0]])).toSucceed();
    });

    it("fails to set admin for non-admin", async () => {
      await expect(send(oracle, "_setAdmin", [accounts[0]], {from: accounts[0]})).rejects.toRevert("revert only the admin may set new admin");
    });
  });

  describe("_setGuardian", () => {
    it("set guardian successfully", async () => {
      expect(await send(oracle, "_setGuardian", [accounts[0]])).toSucceed();
    });

    it("fails to set guardian for non-admin", async () => {
      await expect(send(oracle, "_setGuardian", [accounts[0]], {from: accounts[0]})).rejects.toRevert("revert only the admin may set new guardian");
    });
  });

  describe("_setLPs", () => {
    it("set LPs successfully", async () => {
      expect(await send(oracle, "_setLPs", [[cOther._address], [true]])).toSucceed();
    });

    it("fails to set LPs for non-admin", async () => {
      await expect(send(oracle, "_setLPs", [[cOther._address], [true]], {from: accounts[0]})).rejects.toRevert("revert only the admin may set LPs");
    });

    it("fails to set LPs for mismatched data", async () => {
      await expect(send(oracle, "_setLPs", [[cOther._address], [true, true]])).rejects.toRevert("revert mismatched data");
    });
  });

  describe("_setSymbols", () => {
    const underlyingSymbol = "SYMBOL";
    let token;

    beforeEach(async () => {
      token = await makeToken();
    });

    it("set symbol successfully", async () => {
      expect(await send(oracle, "_setSymbols", [[token._address], [underlyingSymbol]])).toSucceed();
    });

    it("fails to set symbol for non-admin", async () => {
      await expect(send(oracle, "_setSymbols", [[token._address], [underlyingSymbol]], {from: accounts[0]})).rejects.toRevert("revert only the admin or guardian may set symbols");
      expect(await send(oracle, "_setGuardian", [accounts[0]])).toSucceed();
      await expect(send(oracle, "_setSymbols", [[token._address], [underlyingSymbol]], {from: accounts[0]})).rejects.toRevert("revert guardian may only clear the symbol");
    });

    it("fails to set symbol for mismatched data", async () => {
      await expect(send(oracle, "_setSymbols", [[token._address], []])).rejects.toRevert("revert mismatched data");
    });

    it("clear symbol successfully", async () => {
      expect(await send(oracle, "_setGuardian", [accounts[0]])).toSucceed();
      expect(await send(oracle, "_setSymbols", [[token._address], [""]], {from: accounts[0]})).toSucceed();
    });
  });
});
