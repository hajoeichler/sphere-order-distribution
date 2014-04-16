_ = require 'underscore'
Config = require '../config'
OrderDistribution = require '../lib/orderdistribution'
Q = require('q')

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 20000

describe '#distributeOrders', ->
  beforeEach ->
    options =
      baseConfig:
        logConfig: {}
      master: Config.config
      retailer: Config.config
    @distribution = new OrderDistribution options

  it 'Nothing to do', (done) ->
    @distribution.distributeOrders([])
    .then (msg) ->
      expect(msg).toBe 'Nothing to do.'
      done()
    .fail (err) ->
      console.error err
      done err

  it 'should distribute one order', (done) ->
    unique = new Date().getTime()
    pt =
      name: "PT-#{unique}"
      description: 'bla'
      attributes: [
        { name: 'mastersku', label: { de: 'Master SKU' }, type: { name: 'text' }, isRequired: false, inputHint: 'SingleLine' }
      ]
    console.log 0
    @distribution.masterClient.productTypes.save(pt)
    .then (result) =>
      console.log 1
      pt = result
      pMaster =
        productType:
          typeId: 'product-type'
          id: pt.id
        name:
          en: "Master-P-#{unique}"
        slug:
          en: "master-p-#{unique}"
        masterVariant:
          sku: "masterSku#{unique}"
      @distribution.masterClient.products.save(pMaster)
    .then (result) =>
      console.log 2
      pRetailer =
        productType:
          typeId: 'product-type'
          id: pt.id
        name:
          en: "P-#{unique}"
        slug:
          en: "p-#{unique}"
        masterVariant:
          sku: "retailerSku#{unique}"
          attributes: [
            { name: 'mastersku', value: "masterSku#{unique}"  }
          ]
      @distribution.retailerClient.products.save(pRetailer)
    .then (result) =>
      console.log 3
      @distribution.inventoryUpdater.ensureChannelByKey(@distribution.masterClient._rest, @distribution.retailerProjectKey)
    .then (channel) =>
      console.log 4
      o =
        lineItems: [ {
          supplyChannel:
            id: channel.id
            typeId: 'channel'
          variant:
            sku: "masterSku#{unique}"
          name:
            de: 'foo'
          taxRate:
            name: 'myTax'
            amount: 0.10
            includedInPrice: false
            country: 'DE'
          quantity: 1
          price:
            value:
              centAmount: 999
              currencyCode: 'EUR'
        } ]
        totalPrice:
          currencyCode: 'EUR'
          centAmount: 999
      @distribution.importOrder(o)
    .then (order) =>
      console.log 5
      @distribution.run().then (msg) =>
        console.log 6
        expect(msg).toEqual [ [ 'Order sync info successfully stored.', 'Order sync info successfully stored.'] ]
        @distribution.masterClient.orders.byId(order.id).fetch()
        .then (result) =>
          console.log 7
          expect(result.syncInfo).toBeDefined()
          @distribution.retailerClient.orders.where("syncInfo(externalId = \"#{order.id}\")").fetch()
          .then (result) ->
            console.log 8
            expect(result.total).toBe 1
            done()
    .fail (err) ->
      console.error err
      done err