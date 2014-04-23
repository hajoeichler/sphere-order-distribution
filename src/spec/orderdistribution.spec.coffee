_ = require 'underscore'
_.mixin require('sphere-node-utils')._u
{ExtendedLogger} = require 'sphere-node-utils'
package_json = require '../package.json'
Config = require '../config'
OrderDistribution = require '../lib/orderdistribution'

describe 'OrderDistribution', ->

  beforeEach ->
    @logger = new ExtendedLogger
      additionalFields:
        project_key: Config.config.project_key
      logConfig:
        name: "#{package_json.name}-#{package_json.version}"
        streams: [
          { level: 'info', stream: process.stdout }
        ]

    options =
      baseConfig:
        logConfig:
          logger: @logger.bunyanLogger
      master: Config.config
      retailer: Config.config
    @distribution = new OrderDistribution @logger, options

  it 'should throw error that there is no config', ->
    expect(-> new OrderDistribution({})).toThrow new Error 'No base configuration in options!'
    expect(-> new OrderDistribution({}, {})).toThrow new Error 'No base configuration in options!'

  describe '#_validateSameChannel', ->

    it 'should be true for one channel', ->
      o =
        lineItems: [
          { channel:
            key: 'retailer1' }
        ]
      expect(@distribution._validateSameChannel(o)).toBe true


    it 'should be true for same channel', ->
      o =
        lineItems: [
          channel: { id: 'retailer1' }
          variant:
            prices: [ { channel: { id: 'retailer1' } } ]
        ]
      expect(@distribution._validateSameChannel(o)).toBe true

    it 'should be false for different channels', ->
      o =
        lineItems: [
          supplyChannel: { id: 'retailer1' }
          variant:
            prices: [ { channel: id: 'someOther' } ]
        ]
      expect(@distribution._validateSameChannel(o)).toBe false

  describe '#_extractSKUs', ->

    it 'should extract line item skus', ->
      o =
        lineItems: [
          { variant:
            sku: 'mySKU1' }
          { variant:
            sku: 'mySKU2' }
        ]
      skus = @distribution._extractSKUs o
      expect(skus.length).toBe 2
      expect(skus[0]).toBe 'mySKU1'
      expect(skus[1]).toBe 'mySKU2'

  describe '#_matchSKUs', ->

    it 'should matching masterVariant', ->
      p =
        masterVariant:
          sku: 'ret1'
          attributes: [
            { name: 'mastersku', value: 'master1' }
          ]
      m2r = @distribution._matchSKUs([p])
      expect(_.size(m2r)).toBe 1
      expect(m2r.master1).toBe 'ret1'

    it 'should matching variant', ->
      p =
        masterVariant: { attributes: [] }
        variants: [
          { sku: 'retV1', attributes: [ { name: 'mastersku', value: 'm2' } ] }
          { sku: 'retV2', attributes: [ { name: 'mastersku', value: 'm1' } ] }
        ]
      m2r = @distribution._matchSKUs([p])
      expect(_.size(m2r)).toBe 2
      expect(m2r.m1).toBe 'retV2'
      expect(m2r.m2).toBe 'retV1'

  describe '#_replaceSKUs', ->

    it 'should switch variant SKU', ->
      o =
        lineItems: [
          { variant:
            sku: 'mSKU' }
        ]
      m2r = []
      m2r.mSKU = 'oSKU'

      e = @distribution._replaceSKUs o, m2r
      expect(e.lineItems[0].variant.sku).toBe 'oSKU'

    xit 'should create masterSKU attribute with right value', ->
      o =
        lineItems: [
          { variant:
            sku: 'masterSKU1' }
        ]
      masterSKU2retailerSKU = []
      masterSKU2retailerSKU.masterSKU1 = 'retailerSKUx'

      e = @distribution._replaceSKUs o, masterSKU2retailerSKU
      expect(e.lineItems[0].variant.attributes[0].name).toBe 'mastersku'
      expect(e.lineItems[0].variant.attributes[0].value).toBe 'masterSKU1'

  describe '#_removeIdsAndVariantData', ->

    it 'should remove product id', ->
      o =
        lineItems: [
          { productId: 'foo' }
        ]

      e = @distribution._removeIdsAndVariantData o
      expect(e.lineItems[0].productId).toBeUndefined()

    it 'should remove variant id', ->
      o =
        lineItems: [
          { variant: { id: 'bar'} }
        ]

      e = @distribution._removeIdsAndVariantData o
      expect(e.lineItems[0].variant.id).toBeUndefined()

    it 'should remove line item channels', ->
      o =
        lineItems: [
          { supplyChannel: { key: 'retailer1' } }
        ]

      e = @distribution._removeIdsAndVariantData o
      expect(e.lineItems[0].supplyChannel).toBeUndefined()

    it 'should remove channels from variant prices', ->
      o =
        lineItems: [
          { variant: { prices: [] } }
        ]
      p =
        country: 'DE'
        channel:
          key: 'retailerX'
      o.lineItems[0].variant.prices.push p

      e = @distribution._removeIdsAndVariantData o
      expect(e.lineItems[0].variant.prices[0].channel).toBeUndefined()

  describe '#_filterUnsyncedOrders', ->

    it 'should query orders without sync info', ->
      unsyncedOrders = [
        { syncInfo: [], lineItems: [ { supplyChannel: { id: 'someThingElseId' } } ] }
        { syncInfo: [], lineItems: [ { supplyChannel: { id: 'myChannelId' } } ] }
        { syncInfo: [] }
      ]
      filtered = @distribution._filterUnsyncedOrders(unsyncedOrders, 'myChannelId')
      expect(filtered.length).toBe 1

  describe '#_updateSyncInfo', ->

    it 'should post sync info', (done) ->
      spyOn(@distribution.masterClient._rest, "POST").andCallFake((path, payload, callback) ->
        callback(null, {statusCode: 200}, null))

      @distribution._updateSyncInfo(@distribution.masterClient, 'x', 1, 'y', 'z').then =>
        expectedAction =
          version: 1
          actions: [
            action: 'updateSyncInfo'
            channel:
              typeId: 'channel'
              id: 'y'
            externalId: 'z'
          ]
        expect(@distribution.masterClient._rest.POST).toHaveBeenCalledWith("/orders/x", expectedAction, jasmine.any(Function))
        done()
      .fail (err) -> done _.prettify err
