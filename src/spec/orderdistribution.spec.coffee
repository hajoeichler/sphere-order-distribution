OrderDistribution = require('../main').OrderDistribution

describe 'OrderDistribution', ->
  it 'should throw error that there is no config', ->
    expect(-> new OrderDistribution()).toThrow new Error 'No configuration in options!'
    expect(-> new OrderDistribution({})).toThrow new Error 'No configuration in options!'

describe '#run', ->
  beforeEach ->
    c =
      project_key: 'x'
      client_id: 'y'
      client_secret: 'z'
    @distribution = new OrderDistribution { config: c }

  it 'should throw error if callback is passed', ->
    expect(=> @distribution.run()).toThrow new Error 'Callback must be a function!'