OrderDistribution = require('./main').OrderDistribution

exports.process = function(msg, cfg, cb, snapshot) {
  options = {
    master: {
      project_key: cfg.masterProjectKey,
      client_id: cfg.masterClientId,
      client_secret: cfg.masterClientSecret
    },
    retailer: {
      project_key: cfg.retailerProjectKey,
      client_id: cfg.retailerClientId,
      client_secret: cfg.retailerClientSecret
    }
  }
  var oss = new OrderDistribution(options);
  oss.elasticio(msg, cfg, cb, snapshot);
}
