module.exports = {
  networks: {
  },

  mocha: {
  },

  compilers: {
    solc: {
      version: "0.8.4",
      settings: {          // See the solidity docs for advice about optimization and evmVersion
        optimizer: {
          enabled: false,
          runs: 200
        },
      }
    }
  }
};
