_ = require('underscore')._
Config = require '../config'
OrderDistribution = require('../main').OrderDistribution
Q = require('q')

# Increase timeout
jasmine.getEnv().defaultTimeoutInterval = 20000

describe '#run', ->
  beforeEach ->
    @distribution = new OrderDistribution Config

  it 'Nothing to do', (done) ->
    @distribution.run [], (msg) ->
      expect(msg.status).toBe true
      expect(msg.msg).toBe 'Nothing to do.'
      done()

  it 'should distribute one order', (done) ->
    o =
      lineItems: [ {
        sku: 'mySKU'
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
        expect(msg.msg).toBe 'Order exportInfo successfully stored.'
        done()
    .fail (msg) ->
      console.log msg
      expect(true).toBe false
      done()