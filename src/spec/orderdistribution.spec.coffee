_ = require 'underscore'
OrderDistribution = require '../lib/orderdistribution'

describe 'OrderDistribution', ->
  it 'should throw error that there is no config', ->
    expect(-> new OrderDistribution()).toThrow new Error 'No base configuration in options!'
    expect(-> new OrderDistribution({})).toThrow new Error 'No base configuration in options!'

createOD = ->
  c =
    baseConfig:
      logConfig: {}
    master:
      project_key: 'x'
      client_id: 'y'
      client_secret: 'z'
    retailer:
      project_key: 'a'
      client_id: 'b'
      client_secret: 'c'
  new OrderDistribution c

describe '#validateSameChannel', ->
  beforeEach ->
    @distribution = createOD()

  it 'should be true for one channel', ->
    o =
      lineItems: [
        { channel:
          key: 'retailer1' }
      ]
    expect(@distribution.validateSameChannel(o)).toBe true


  it 'should be true for same channel', ->
    o =
      lineItems: [
        channel: { id: 'retailer1' }
        variant:
          prices: [ { channel: { id: 'retailer1' } } ]
      ]
    expect(@distribution.validateSameChannel(o)).toBe true

  it 'should be false for different channels', ->
    o =
      lineItems: [
        supplyChannel: { id: 'retailer1' }
        variant:
          prices: [ { channel: id: 'someOther' } ]
      ]
    expect(@distribution.validateSameChannel(o)).toBe false

describe '#extractSKUs', ->
  beforeEach ->
    @distribution = createOD()

  it 'should extract line item skus', ->
    o =
      lineItems: [
        { variant:
          sku: 'mySKU1' }
        { variant:
          sku: 'mySKU2' }
      ]
    skus = @distribution.extractSKUs o
    expect(skus.length).toBe 2
    expect(skus[0]).toBe 'mySKU1'
    expect(skus[1]).toBe 'mySKU2'

describe '#matchSKUs', ->
  beforeEach ->
    @distribution = createOD()

  it 'should matching masterVariant', ->
    p =
      masterVariant:
        sku: 'ret1'
        attributes: [
          { name: 'mastersku', value: 'master1' }
        ]
    m2r = @distribution.matchSKUs([p])
    expect(_.size(m2r)).toBe 1
    expect(m2r.master1).toBe 'ret1'

  it 'should matching variant', ->
    p =
      masterVariant: { attributes: [] }
      variants: [
        { sku: 'retV1', attributes: [ { name: 'mastersku', value: 'm2' } ] }
        { sku: 'retV2', attributes: [ { name: 'mastersku', value: 'm1' } ] }
      ]
    m2r = @distribution.matchSKUs([p])
    expect(_.size(m2r)).toBe 2
    expect(m2r.m1).toBe 'retV2'
    expect(m2r.m2).toBe 'retV1'

describe '#replaceSKUs', ->
  beforeEach ->
    @distribution = createOD()

  it 'should switch variant SKU', ->
    o =
      lineItems: [
        { variant:
          sku: 'mSKU' }
      ]
    m2r = []
    m2r.mSKU = 'oSKU'

    e = @distribution.replaceSKUs o, m2r
    expect(e.lineItems[0].variant.sku).toBe 'oSKU'

  xit 'should create masterSKU attribute with right value', ->
    o =
      lineItems: [
        { variant:
          sku: 'masterSKU1' }
      ]
    masterSKU2retailerSKU = []
    masterSKU2retailerSKU.masterSKU1 = 'retailerSKUx'

    e = @distribution.replaceSKUs o, masterSKU2retailerSKU
    expect(e.lineItems[0].variant.attributes[0].name).toBe 'mastersku'
    expect(e.lineItems[0].variant.attributes[0].value).toBe 'masterSKU1'

describe '#removeIdsAndVariantData', ->
  beforeEach ->
    @distribution = createOD()

  it 'should remove product id', ->
    o =
      lineItems: [
        { productId: 'foo' }
      ]

    e = @distribution.removeIdsAndVariantData o
    expect(e.lineItems[0].productId).toBeUndefined()

  it 'should remove variant id', ->
    o =
      lineItems: [
        { variant: { id: 'bar'} }
      ]

    e = @distribution.removeIdsAndVariantData o
    expect(e.lineItems[0].variant.id).toBeUndefined()

  it 'should remove line item channels', ->
    o =
      lineItems: [
        { supplyChannel: { key: 'retailer1' } }
      ]

    e = @distribution.removeIdsAndVariantData o
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

    e = @distribution.removeIdsAndVariantData o
    expect(e.lineItems[0].variant.prices[0].channel).toBeUndefined()

xdescribe '#getUnSyncedOrders', ->
  beforeEach ->
    @distribution = createOD()

  it 'should query orders without sync info', (done) ->
    spyOn(@distribution.masterClient._rest, "GET").andCallFake((path, callback) ->
      body =
        results: [
          { syncInfo: [], lineItems: [ { supplyChannel: { id: 'someThingElseId' } } ] }
          { syncInfo: [], lineItems: [ { supplyChannel: { id: 'myChannelId' } } ] }
          { syncInfo: [ {} ] }
        ]
      callback(null, {statusCode: 200}, body))

    @distribution.getUnSyncedOrders(@distribution.masterClient, 'myChannelId')
    .then (orders) =>
      expect(_.size(orders)).toBe 1
      expect(@distribution.masterClient._rest.GET).toHaveBeenCalledWith(/orders/, jasmine.any(Function))
      done()
    .fail (err) ->
      console.error err
      done err

describe '#getRetailerProductByMasterSKU', ->
  beforeEach ->
    @distribution = createOD()

  it 'should query for products with several skus', (done) ->
    spyOn(@distribution.retailerClient._rest, "GET").andCallFake((path, callback) ->
      callback(null, {statusCode: 200}, results: [{}] ))

    @distribution.getRetailerProductByMasterSKU('foo').then =>
      uri = "/product-projections/search?staged=true&lang=de&filter=variants.attributes.mastersku%3A%22foo%22"
      expect(@distribution.retailerClient._rest.GET).toHaveBeenCalledWith(uri, jasmine.any(Function))
      done()
    .fail (err) ->
      console.error err
      done err

describe '#addSyncInfo', ->
  beforeEach ->
    @distribution = createOD()

  it 'should post sync info', (done) ->
    spyOn(@distribution.masterClient._rest, "POST").andCallFake((path, payload, callback) ->
      callback(null, {statusCode: 200}, null))

    @distribution.addSyncInfo(@distribution.masterClient, 'x', 1, 'y', 'z').then =>
      expectedAction =
        version: 1
        actions: [
          action: 'updateSyncInfo'
          channel:
            typeId: 'channel'
            id: 'y'
          externalId: 'z'
        ]
      expect(@distribution.masterClient._rest.POST).toHaveBeenCalledWith("/orders/x", JSON.stringify(expectedAction), jasmine.any(Function))
      done()
    .fail (err) ->
      console.error err
      done err
