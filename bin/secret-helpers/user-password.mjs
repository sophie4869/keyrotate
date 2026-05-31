// Update an auth-backend user's password.
//   $set:   { password: bcrypt(plain, 12), updated_at: <now> }
//   $unset: { resetPasswordToken, resetPasswordExpires }
//
// Mirrors utils/db.js#updatePassword in the s0phi3 auth backend so the schema
// stays consistent.
//
// Required env: MONGODB_URI, USERNAME, PASSWORD
// Optional env: DB_NAME (default 's0phi3_users'), COLLECTION (default 'users'),
//               BCRYPT_ROUNDS (default 12).
//
// Exit codes:
//   0 = updated   2 = user not found   1 = any other failure

import bcrypt from 'bcrypt';
import { MongoClient } from 'mongodb';

const {
  MONGODB_URI,
  USERNAME,
  PASSWORD,
  DB_NAME = 's0phi3_users',
  COLLECTION = 'users',
  BCRYPT_ROUNDS = '12',
} = process.env;

for (const k of ['MONGODB_URI', 'USERNAME', 'PASSWORD']) {
  if (!process.env[k]) {
    console.error(`❌ missing required env var: ${k}`);
    process.exit(1);
  }
}

const rounds = Number.parseInt(BCRYPT_ROUNDS, 10);
if (!Number.isFinite(rounds) || rounds < 4 || rounds > 15) {
  console.error(`❌ BCRYPT_ROUNDS out of range: ${BCRYPT_ROUNDS}`);
  process.exit(1);
}

const hashed = await bcrypt.hash(PASSWORD, rounds);

const client = new MongoClient(MONGODB_URI, { serverSelectionTimeoutMS: 10_000 });
try {
  await client.connect();
  const db = client.db(DB_NAME);
  const result = await db.collection(COLLECTION).updateOne(
    { username: USERNAME },
    {
      $set:   { password: hashed, updated_at: new Date() },
      $unset: { resetPasswordToken: '', resetPasswordExpires: '' },
    }
  );
  if (result.matchedCount === 0) {
    console.error(`❌ no user with username='${USERNAME}' in ${DB_NAME}.${COLLECTION}`);
    process.exit(2);
  }
  console.log(`matched=${result.matchedCount} modified=${result.modifiedCount}`);
} catch (err) {
  console.error(`❌ mongo error: ${err.message}`);
  process.exit(1);
} finally {
  await client.close().catch(() => {});
}
