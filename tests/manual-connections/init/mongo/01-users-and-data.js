const lab = db.getSiblingDB('tablepro_lab');
lab.createUser({
  user: 'tablepro_rw',
  pwd: 'tablepro_rw_password',
  roles: [{ role: 'readWrite', db: 'tablepro_lab' }],
});
lab.createUser({
  user: 'tablepro_ro',
  pwd: 'tablepro_ro_password',
  roles: [{ role: 'read', db: 'tablepro_lab' }],
});
lab.people.insertMany([
  { _id: 1, name: 'Ada Lovelace', email: 'ada@example.test', active: true },
  { _id: 2, name: 'Grace Hopper', email: 'grace@example.test', active: false },
]);
