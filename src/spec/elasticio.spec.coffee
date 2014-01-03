elasticio = require('../elasticio.js')

describe "elasticio integration", ->

  beforeEach ->
    @cfg =
      masterProjectKey: 'x'
      masterClientId: 'y'
      masterClientSecret: 'z'
      retailerProjectKey: 'a'
      retailerClientId: 'b'
      retailerClientSecret: 'c'

  it "no body", (done) ->
    msg = ''
    elasticio.process msg, @cfg, (next) ->
      expect(next.status).toBe false
      expect(next.msg).toBe 'No data found in elastic.io msg!'
      done()

  it "no orders", (done) ->
    msg =
      body:
        results: []
    elasticio.process msg, @cfg, (next) ->
      expect(next.status).toBe true
      expect(next.msg).toBe 'Nothing to do.'
      done()