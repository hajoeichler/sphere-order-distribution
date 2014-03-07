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
      attributes: [
        { name: 'mastersku', label: { de: 'Master SKU' }, type: { name: 'text' }, isRequired: false, inputHint: 'SingleLine' }
      ]
    @distribution.masterRest.POST '/product-types', pt, (error, response, body) =>
      expect(response.statusCode).toBe 201
      pt = body
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
      @distribution.masterRest.POST '/products', pMaster, (error, response, body) =>
        expect(response.statusCode).toBe 201
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
        @distribution.masterRest.POST '/products', pRetailer, (error, response, body) =>
          expect(response.statusCode).toBe 201
          o =
            lineItems: [ {
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
          @distribution.importOrder(o).then (order) =>
            @distribution.run [order], (msg) =>
              expect(msg.status).toBe true
              expect(msg.message).toEqual [ 'Order sync info successfully stored.', 'Order sync info successfully stored.']
              @distribution.masterRest.GET "/orders/#{order.id}", (error, response, body) =>
                expect(body.syncInfo).toBeDefined()
                query = encodeURIComponent "syncInfo(externalId = \"#{order.id}\")"
                @distribution.masterRest.GET "/orders?where=#{query}", (error, response, body) ->
                  expect(body.total).toBe 1
                  done()
          .fail (msg) ->
            console.log msg
            expect(true).toBe false
            done()