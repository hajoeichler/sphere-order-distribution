elasticio = require('../elasticio.js')
Config = require '../config'

describe "elasticio integration", ->
  it "no body", (done) ->
    cfg =
      clientId: 'some'
      clientSecret: 'stuff'
      projectKey: 'here'
    msg = ''
    elasticio.process msg, cfg, (next) ->
      expect(next.status).toBe false
      expect(next.msg).toBe 'No data found in elastic.io msg!'
      done()