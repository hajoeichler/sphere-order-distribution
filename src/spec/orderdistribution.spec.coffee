OrderDistribution = require('../main').OrderDistribution

describe 'OrderDistribution', ->
  it 'should throw error that there is no config', ->
    expect(-> new OrderDistribution()).toThrow new Error 'No configuration in options!'
    expect(-> new OrderDistribution({})).toThrow new Error 'No configuration in options!'

createOD = () ->
  c =
    project_key: 'x'
    client_id: 'y'
    client_secret: 'z'
  new OrderDistribution { config: c }

describe '#run', ->
  beforeEach ->
    @distribution = createOD()

  it 'should throw error if callback is passed', ->
    expect(=> @distribution.run()).toThrow new Error 'Callback must be a function!'

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

describe '#removeChannels  ', ->
  beforeEach ->
    @distribution = createOD()

  it 'should remove line item channels', ->
    o =
      lineItems: [
        { channel:
          key: 'retailer1' }
      ]

    e = @distribution.removeChannels o
    expect(e.lineItems.channel).toBeUndefined

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

    e = @distribution.removeChannels o
    expect(e.lineItems.channel).toBeUndefined
