const NATS = require('nats');

async function main() {
  const nc = await NATS.connect({ servers: 'nats://172.29.155.146:4222' });
  const jsm = await nc.jetstreamManager();

  // Create a durable consumer for the Zeabur control plane
  try {
    const consumer = await jsm.consumers.add('KUBEWATCH', {
      name: 'zeabur-control-plane',
      durable_name: 'zeabur-control-plane',
      ack_policy: 'explicit',
      deliver_policy: 'all',
      filter_subject: 'events.>',
      max_ack_pending: 1000,
      inactive_threshold: 24 * 60 * 60 * 1e9, // 24h ns
    });
    console.log('Created consumer:', consumer.name);
  } catch (e) {
    console.error('Consumer error:', e.message);
  }

  // List consumers
  const consumers = await jsm.consumers.list('KUBEWATCH').next();
  console.log('Consumers:', consumers.map(c => c.name));

  await nc.close();
}

main().catch(e => { console.error(e); process.exit(1); });
