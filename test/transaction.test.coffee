# Tests for Op(erations)
should = require 'should'
transaction = require 'transaction'
pathParser = require 'pathParser.server'
require 'transaction.server'

# transaction object literal
txn = transaction.create base: 2, id: '4.0', method: 'set', args: ['count', 1]

module.exports =
  # Property getters

  'test transaction.base': ->
    transaction.base(txn).should.eql 2

  'test transaction.id': ->
    transaction.id(txn).should.eql '4.0'

  'test transaction.method': ->
    transaction.method(txn).should.eql 'set'

  'test transaction.args': ->
    transaction.args(txn).should.eql ['count', 1]

  'test transaction.path': ->
    transaction.path(txn).should.eql 'count'

  # Property setters

  'test transaction.base setter': ->
    txn = transaction.create base: 2, id: '4.0', method: 'set', args: ['count', 1]
    transaction.base(txn).should.equal 2
    transaction.base txn, 3
    transaction.base(txn).should.equal 3

  'test transaction.id setter': ->
    txn = transaction.create base: 2, id: '4.0', method: 'set', args: ['count', 1]
    transaction.id(txn).should.equal '4.0'
    transaction.id txn, '4.1'
    transaction.id(txn).should.equal '4.1'

  'test transaction.method setter': ->
    txn = transaction.create base: 2, id: '4.0', method: 'set', args: ['count', 1]
    transaction.method(txn).should.equal 'set'
    transaction.method txn, 'del'
    transaction.method(txn).should.equal 'del'

  'test transaction.args setter': ->
    txn = transaction.create base: 2, id: '4.0', method: 'set', args: ['count', 1]
    transaction.args(txn).should.eql ['count', 1]
    transaction.args txn, ['count', 9]
    transaction.args(txn).should.eql ['count', 9]

  'test transaction.path setter': ->
    txn = transaction.create base: 2, id: '4.0', method: 'set', args: ['count', 1]
    transaction.path(txn).should.equal 'count'
    transaction.path txn, 'age'
    transaction.path(txn).should.equal 'age'

  # Evaluating (but not applying) transactions

  # Applying transactions

  # Path Conflict Detection

  'paths where neither is a sub-path of the other should not conflict': ->
    transaction.pathConflict('abc', 'def').should.be.false
    transaction.pathConflict('def', 'abc').should.be.false # symmetric
    transaction.pathConflict('abc.de', 'abc.def').should.be.false
    transaction.pathConflict('abc.def', 'abc.de').should.be.false # symmetric

  'paths where one is a sub-path of the other should conflict': ->
    transaction.pathConflict('abc', 'abc.def').should.be.true
    transaction.pathConflict('abc.def', 'abc').should.be.true # symmetric
    transaction.pathConflict('abc', 'abc').should.be.true

  # Transaction Conflict Detection
  
  'test conflict detection between transactions': ->
    txn0 = transaction.create base: 0, id: '1.0', method: 'set', args: ['count', 1]
    txn1 = transaction.create base: 0, id: '1.0', method: 'set', args: ['count', 1]
    txn2 = transaction.create base: 0, id: '0.0', method: 'set', args: ['count', 0]
    txn3 = transaction.create base: 0, id: '0.0', method: 'del', args: ['count', 1]
    txn4 = transaction.create base: 0, id: '0.0', method: 'set', args: ['count', 1, 0]
    txn5 = transaction.create base: 0, id: '0.1', method: 'set', args: ['count', 1]
    txn6 = transaction.create base: 0, id: '0.1', method: 'set', args: ['name', 'drago']
    
    txn2s = transaction.create base: 0, id: '#0.0', method: 'set', args: ['count', 1]
    txn5s = transaction.create base: 0, id: '#0.1', method: 'set', args: ['count', 1]
    
    txn7 = transaction.create base: 0, id: '1.0', method: 'set', args: ['obj.nested', 0]
    txn8 = transaction.create base: 0, id: '2.0', method: 'set', args: ['obj.nested.a', 0]
    
    transaction.conflict(txn1, txn2).should.eql 'conflict' # Different arguments
    transaction.conflict(txn1, txn3).should.eql 'conflict' # Different method
    transaction.conflict(txn1, txn4).should.eql 'conflict' # Different number of arguments
    
    transaction.conflict(txn2, txn5).should.eql 'conflict' # Same client, wrong order
    transaction.conflict(txn5, txn2).should.be.false # Same client, correct order
    transaction.conflict(txn2s, txn5s).should.eql 'conflict' # Same store, wrong order
    transaction.conflict(txn5s, txn2s).should.eql 'conflict' # Same store, correct order
    
    transaction.conflict(txn1, txn6).should.be.false # Non-conflicting paths
    
    transaction.conflict(txn7, txn8).should.eql 'conflict' # Conflicting nested paths
    transaction.conflict(txn8, txn7).should.eql 'conflict' # Conflicting nested paths
    
    transaction.conflict(txn0, txn1).should.eql 'duplicate' # Same transaction ID
