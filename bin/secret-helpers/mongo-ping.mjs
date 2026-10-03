// Connect with $MONGODB_URI and ping. Exit 0 if the credentials authenticate.
// Used by `secret` after rotating/setting a Mongo URI. Reads the URI from the
// environment only, so it never shows up in argv / `ps`.
import { MongoClient } from 'mongodb';

const uri = process.env.MONGODB_URI;
if (!uri) { console.error('MONGODB_URI not set'); process.exit(2); }
const client = new MongoClient(uri, { serverSelectionTimeoutMS: 10_000 });
try {
  await client.connect();
  await client.db('admin').command({ ping: 1 });
  process.exit(0);
} catch (e) {
  console.error(e?.codeName || e?.name || 'error');
  process.exit(1);
} finally {
  await client.close().catch(() => {});
}
