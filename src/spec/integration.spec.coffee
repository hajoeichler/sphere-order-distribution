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