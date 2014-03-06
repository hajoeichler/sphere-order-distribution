_ = require('underscore')._
Config = require '../config'
OrderDistribution = require('../main').OrderDistribution
Q = require('q')

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 20000

describe '#run', ->
  beforeEach ->
    options =
      master: Config.config
      retailer: Config.config
    @distribution = new OrderDistribution options

  it 'Nothing to do', (done) ->
    @distribution.run [], (msg) ->
      expect(msg.status).toBe true
      expect(msg.message).toBe 'Nothing to do.'
      done()

  it 'should distribute one order', (done) ->
    unique = new Date().getTime()
    pt =
      name: "PT-#{unique}"
      description: 'bla'
    @distribution.masterRest.POST '/product-types', pt, (error, response, body) =>
      expect(response.statusCode).toBe 201
      p =
        productType:
          typeId: 'product-type'
          id: body.id
        name:
          en: "P-#{unique}"
        slug:
          en: "p-#{unique}"
        masterVariant:
          sku: "sku-#{unique}"
      @distribution.masterRest.POST '/products', p, (error, response, body) =>
        expect(response.statusCode).toBe 201
        o =
          lineItems: [ {
            variant:
              sku: "sku-#{unique}"
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
        @distribution.importOrder(o).then (order) =>
          @distribution.run [order], (msg) ->
            expect(msg.status).toBe true
            expect(msg.message).toBe 'Order sync info successfully stored.'
          done()
        .fail (msg) ->
          console.log msg
          expect(true).toBe false
          done()