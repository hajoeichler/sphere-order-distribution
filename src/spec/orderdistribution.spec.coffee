_ = require('underscore')._
OrderDistribution = require('../main').OrderDistribution

describe 'OrderDistribution', ->
  it 'should throw error that there is no config', ->
    expect(-> new OrderDistribution()).toThrow new Error 'No master configuration in options!'
    expect(-> new OrderDistribution({})).toThrow new Error 'No master configuration in options!'

createOD = () ->
  c =
    master:
      project_key: 'x'
      client_id: 'y'
      client_secret: 'z'
    retailer:
      project_key: 'a'
      client_id: 'b'
      client_secret: 'c'
  new OrderDistribution c

describe '#run', ->
  beforeEach ->
    @distribution = createOD()

  it 'should throw error if callback is passed', ->
    expect(=> @distribution.run()).toThrow new Error 'Callback must be a function!'

  it 'should do nothing', (done) ->
    @distribution.run [], (msg) ->
      expect(msg.status).toBe true
      expect(msg.message).toBe 'Nothing to do.'
      done()

  it 'should tell that there is an order with different channels', (done) ->
    o =
      id: 'foo'
      lineItems: [
        { supplyChannel: { id: '123' } }
        { supplyChannel: { id: '234' } }
      ]
    @distribution.run [o], (msg) ->
      expect(msg.status).toBe false
      expect(msg.message).toBe "The order 'foo' has different channels set!"
      done()

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

describe '#ensureAllSKUs', ->
  beforeEach ->
    @distribution = createOD()

  it 'should return true for empty inputs', ->
    m2r = {}
    skus = []
    expect(@distribution.ensureAllSKUs(m2r, skus))

  it 'should return true if all SKUs are matched', ->
    m2r =
      123: 234
    skus = [ '123' ]
    expect(@distribution.ensureAllSKUs(m2r, skus))

  it 'should return false if not all SKUs are in the match', ->
    m2r =
      123: 234
    skus = [ '123', 'foo' ]
    expect(@distribution.ensureAllSKUs(m2r, skus))


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

  it 'should create masterSKU attribute with right value', ->
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

describe '#removeChannelsAndIds', ->
  beforeEach ->
    @distribution = createOD()

  it 'should remove product id', ->
    o =
      lineItems: [
        { productId: 'foo' }
      ]

    e = @distribution.removeChannelsAndIds o
    expect(e.lineItems[0].productId).toBeUndefined()

  it 'should remove variant id', ->
    o =
      lineItems: [
        { variant: { id: 'bar'} }
      ]

    e = @distribution.removeChannelsAndIds o
    expect(e.lineItems[0].variant.id).toBeUndefined()

  it 'should remove line item channels', ->
    o =
      lineItems: [
        { supplyChannel: { key: 'retailer1' } }
      ]

    e = @distribution.removeChannelsAndIds o
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

    e = @distribution.removeChannelsAndIds o
    expect(e.lineItems[0].variant.prices[0].channel).toBeUndefined()

describe '#getUnSyncedOrders', ->
  beforeEach ->
    @distribution = createOD()

  it 'should query orders without sync info', (done) ->
    spyOn(@distribution.retailerRest, "GET").andCallFake((path, callback) ->
      body =
        results: [
          { syncInfo: [] }
          { syncInfo: [ {} ] }
        ]
      callback(null, {statusCode: 200}, JSON.stringify(body)))

    @distribution.getUnSyncedOrders(@distribution.retailerRest, 0).then (orders) =>
      expect(_.size(orders)).toBe 1
      expectedURI = '/orders?limit=0&where='
      expectedURI += encodeURIComponent "createdAt > \"#{new Date().toISOString().substring(0,10)}T00:00:00.000Z\""
      expect(@distribution.retailerRest.GET).toHaveBeenCalledWith(expectedURI, jasmine.any(Function))
      done()
    .fail (msg) ->
      expect(true).toBe false
      done()

describe '#getRetailerProductByMasterSKU', ->
  beforeEach ->
    @distribution = createOD()

  it 'should query for products with several skus', (done) ->
    spyOn(@distribution.retailerRest, "GET").andCallFake((path, callback) ->
      callback(null, {statusCode: 200}, '{ "results": [] }'))

    @distribution.getRetailerProductByMasterSKU('foo').then () =>
      uri = "/product-projections/search?lang=de&filter=variants.attributes.mastersku%3A%22foo%22"
      expect(@distribution.retailerRest.GET).toHaveBeenCalledWith(uri, jasmine.any(Function))
      done()
    .fail (msg) ->
      expect(true).toBe false
      done()

describe '#addSyncInfo', ->
  beforeEach ->
    @distribution = createOD()

  it 'should post sync info', (done) ->
    spyOn(@distribution.masterRest, "POST").andCallFake((path, payload, callback) ->
      callback(null, {statusCode: 200}, null))

    @distribution.addSyncInfo('x', 1, 'y', 'z').then () =>
      expectedAction =
        version: 1
        actions: [
          action: 'updateSyncInfo'
          channel:
            typeId: 'channel'
            id: 'y'
          externalId: 'z'
        ]
      expect(@distribution.masterRest.POST).toHaveBeenCalledWith("/orders/x", JSON.stringify(expectedAction), jasmine.any(Function))
      done()
    .fail (msg) ->
      expect(true).toBe false
      done()
