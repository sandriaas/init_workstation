const NATS = require('nats');

async function main() {
  const nc = await NATS.connect({ servers: 'nats://172.29.155.146:4222' });
  const jsm = await nc.jetstreamManager();
  try {
    const stream = await jsm.streams.add({
      name: 'KUBEWATCH',
      subjects: ['events.>', 'kube.>', 'pods.>', 'events'],
      retention: 'limits',
      max_msgs: 100000,
      max_bytes: 100 * 1024 * 1024,
      max_age: 24 * 60 * 60 * 1e9, // 24h in ns
      storage: 'file',
      discard: 'old',
      num_replicas: 1,
    });
    console.log('Created stream:', stream.config.name);
  } catch (e) {
    console.error('Error creating stream:', e.message);
  }
  // List streams
  const list = await jsm.streams.list().next();
  console.log('Streams now:', list.map(s => s.config.name));
  await nc.close();
}

main().catch(e => { console.error(e); process.exit(1); });
