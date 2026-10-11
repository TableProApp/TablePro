db = db.getSiblingDB('tablepro');

db.createUser({
  user: 'tablepro',
  pwd: 'tablepro',
  roles: [{ role: 'readWrite', db: 'tablepro' }],
});

db.createCollection('release_items');
db.release_items.insertMany([
  { _id: 1, name: 'alpha', amount: 10 },
  { _id: 2, name: 'beta', amount: 20 },
  { _id: 3, name: 'gamma', amount: 30 },
]);
