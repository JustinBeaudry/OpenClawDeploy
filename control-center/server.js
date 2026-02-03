const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const WebSocket = require('ws');
const http = require('http');
const yaml = require('js-yaml');
const sqlite3 = require('sqlite3').verbose();

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

// --- Logger ---
const logger = {
    info: (msg) => console.log(`[${new Date().toISOString()}] [INFO] ${msg}`),
    error: (msg) => console.error(`[${new Date().toISOString()}] [ERROR] ${msg}`),
    gcloud: (args) => console.log(`[${new Date().toISOString()}] [GCLOUD] Command: gcloud ${args.join(' ')}`)
};

const PROJECT_ROOT = path.resolve(__dirname, '..');
const DEPLOYMENTS_DIR = path.join(PROJECT_ROOT, 'deployments');
const TEMPLATES_DIR = path.join(__dirname, 'templates');
const DB_PATH = path.join(__dirname, 'database.sqlite');

// --- Database Setup ---
const db = new sqlite3.Database(DB_PATH);

db.serialize(() => {
    db.run(`CREATE TABLE IF NOT EXISTS bots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE,
        project_id TEXT,
        zone TEXT,
        status TEXT DEFAULT 'idle',
        last_deployed TEXT,
        tailscale_key TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )`);
});

// Helper to run DB queries as promises
const dbRun = (sql, params = []) => new Promise((resolve, reject) => {
    db.run(sql, params, function(err) {
        if (err) reject(err);
        else resolve(this);
    });
});

const dbAll = (sql, params = []) => new Promise((resolve, reject) => {
    db.all(sql, params, (err, rows) => {
        if (err) reject(err);
        else resolve(rows);
    });
});

const dbGet = (sql, params = []) => new Promise((resolve, reject) => {
    db.get(sql, params, (err, row) => {
        if (err) reject(err);
        else resolve(row);
    });
});

// app.use(cors()); // Disabled for security: Same-origin only
app.use(bodyParser.json());
app.use((req, res, next) => {
    logger.info(`API Request: ${req.method} ${req.originalUrl}`);
    next();
});
app.use(express.static(path.join(__dirname, 'public')));

// --- Sync Filesystem to DB (One-time or on-demand) ---
async function syncDeployments() {
    if (!fs.existsSync(DEPLOYMENTS_DIR)) return;
    const folders = fs.readdirSync(DEPLOYMENTS_DIR, { withFileTypes: true })
        .filter(d => d.isDirectory() && d.name !== 'backups');

    for (const folder of folders) {
        const varsPath = path.join(DEPLOYMENTS_DIR, folder.name, 'vars.yml');
        if (fs.existsSync(varsPath)) {
            try {
                const config = yaml.load(fs.readFileSync(varsPath, 'utf8'));
                // Insert or ignore if exists
                await dbRun(
                    `INSERT OR IGNORE INTO bots (name, project_id, zone, tailscale_key) VALUES (?, ?, ?, ?) `,
                    [folder.name, config.project_id || 'unknown', config.zone || 'us-east5-a', config.tailscale_authkey || '']
                );
            } catch (e) {
                console.error(`Failed to sync ${folder.name}:`, e);
            }
        }
    }
}

syncDeployments();

// --- API ---

// Validation Helper
const isValidName = (name) => /^[a-zA-Z0-9-]+$/.test(name);

// List Deployments (from DB)
app.get('/api/deployments', async (req, res) => {
    try {
        const bots = await dbAll(`SELECT * FROM bots ORDER BY created_at DESC`);
        // Enrich with file-based config if needed
        const enriched = bots.map(bot => {
            const varsPath = path.join(DEPLOYMENTS_DIR, bot.name, 'vars.yml');
            let fileConfig = {};
            if (fs.existsSync(varsPath)) {
                try { fileConfig = yaml.load(fs.readFileSync(varsPath, 'utf8')); } catch (e) {}
            }
            return { ...bot, config: { ...fileConfig, project_id: bot.project_id, zone: bot.zone } };
        });
        res.json(enriched);
    } catch (e) {
        res.status(500).json({ error: e.message });
    }
});

// Create/Update Deployment Config
app.post('/api/deployments/:name', async (req, res) => {
    const { name } = req.params;
    if (!isValidName(name)) {
        return res.status(400).json({ error: "Invalid name. Only alphanumeric characters and hyphens are allowed." });
    }
    const { tailscaleKey, gcpProject, gcpZone, openclawConfig } = req.body;
    
    const deployDir = path.join(DEPLOYMENTS_DIR, name);
    if (!fs.existsSync(deployDir)) fs.mkdirSync(deployDir, { recursive: true });

    // 1. Write vars.yml
    const vars = {
        tailscale_authkey: tailscaleKey || "",
        project_id: gcpProject,
        zone: gcpZone
    };
    fs.writeFileSync(path.join(deployDir, 'vars.yml'), yaml.dump(vars));

    // 2. Write clawdbot.json (if provided)
    if (openclawConfig) {
        fs.writeFileSync(path.join(deployDir, 'clawdbot.json'), JSON.stringify(openclawConfig, null, 2));
    }

    // 3. Update DB
    await dbRun(
        `INSERT INTO bots (name, project_id, zone, tailscale_key) 
         VALUES (?, ?, ?, ?) 
         ON CONFLICT(name) DO UPDATE SET 
            project_id=excluded.project_id, 
            zone=excluded.zone, 
            tailscale_key=excluded.tailscale_key`,
        [name, gcpProject, gcpZone, tailscaleKey]
    );

    res.json({ success: true });
});

// Run Deployment
app.post('/api/deploy/:name', async (req, res) => {
    const { name } = req.params;
    if (!isValidName(name)) {
        return res.status(400).json({ error: "Invalid name. Only alphanumeric characters and hyphens are allowed." });
    }
    const { action, gcpProject, gcpZone } = req.body;
    
    await dbRun(`UPDATE bots SET status = ?, last_deployed = CURRENT_TIMESTAMP WHERE name = ?`, ['deploying', name]);

    res.json({ success: true, message: "Deployment started" });
    
    broadcast(`\n🚀 STARTING DEPLOYMENT: ${action.toUpperCase()} ${name}\n`);

    const env = { 
        ...process.env, 
        GCP_PROJECT_ID: gcpProject || process.env.GCP_PROJECT_ID,
        GCP_ZONE: gcpZone || process.env.GCP_ZONE
    };

    logger.info(`Starting deployment script: ./scripts/manage_deployment.sh ${action} ${name}`);

    const cmd = spawn('./scripts/manage_deployment.sh', [action, name], {
        cwd: PROJECT_ROOT,
        env
    });

    cmd.stdout.on('data', (data) => broadcast(data.toString()));
    cmd.stderr.on('data', (data) => broadcast(data.toString()));
    
    cmd.on('close', async (code) => {
        const finalStatus = code === 0 ? 'active' : 'error';
        await dbRun(`UPDATE bots SET status = ? WHERE name = ?`, [finalStatus, name]);
        broadcast(`\n✅ PROCESS FINISHED WITH EXIT CODE: ${code}\n`);
    });
});

// --- GCP API ---

// Check gcloud Auth
app.get('/api/gcp/auth', (req, res) => {
    const args = ['auth', 'list', '--format=json'];
    logger.gcloud(args);
    const cmd = spawn('gcloud', args);
    let output = '';
    cmd.stdout.on('data', d => output += d);
    cmd.on('close', (code) => {
        if (code !== 0) return res.json({ authenticated: false });
        try {
            const accounts = JSON.parse(output);
            const active = accounts.find(a => a.status === 'ACTIVE');
            res.json({ authenticated: !!active, account: active?.account });
        } catch (e) {
            res.json({ authenticated: false });
        }
    });
});

// List Projects
app.get('/api/gcp/projects', (req, res) => {
    const args = ['projects', 'list', '--format=json'];
    logger.gcloud(args);
    const cmd = spawn('gcloud', args);
    let output = '';
    cmd.stdout.on('data', d => output += d);
    cmd.on('close', () => {
        try { res.json(JSON.parse(output)); } catch (e) { res.json([]); }
    });
});

// Create Project
app.post('/api/gcp/projects', (req, res) => {
    const { projectId, name } = req.body;
    // Note: Creating projects often requires organization selection or falls back to default.
    // This is a basic implementation.
    const args = ['projects', 'create', projectId, '--name', name || projectId, '--format=json'];
    logger.gcloud(args);
    const cmd = spawn('gcloud', args);
    let err = '';
    cmd.stderr.on('data', d => err += d);
    cmd.on('close', (code) => {
        if (code === 0) res.json({ success: true });
        else res.status(500).json({ error: err });
    });
});

// Check Service Status
app.get('/api/gcp/services', (req, res) => {
    const { projectId } = req.query;
    if (!projectId) return res.json({});

    const args = [
        'services', 'list', 
        '--enabled', 
        '--project', projectId, 
        '--format=json(config.name)'
    ];
    logger.gcloud(args);

    const cmd = spawn('gcloud', args);
    
    let output = '';
    cmd.stdout.on('data', d => output += d);
    cmd.on('close', () => {
        try {
            const list = JSON.parse(output);
            const enabledSet = new Set(list.map(i => i.config.name));
            
            const services = {
                'compute.googleapis.com': enabledSet.has('compute.googleapis.com'),
                'gmail.googleapis.com': enabledSet.has('gmail.googleapis.com'),
                'drive.googleapis.com': enabledSet.has('drive.googleapis.com'),
                'people.googleapis.com': enabledSet.has('people.googleapis.com'),
                'calendar.googleapis.com': enabledSet.has('calendar.googleapis.com')
            };
            res.json(services);
        } catch (e) {
            res.json({});
        }
    });
});

// Enable Services
app.post('/api/gcp/services', async (req, res) => {
    const { projectId } = req.body;
    
    // Critical APIs for VM deployment
    const criticalServices = ['compute.googleapis.com'];
    
    // Optional APIs for Bot Skills
    const optionalServices = [
        'gmail.googleapis.com',
        'drive.googleapis.com',
        'people.googleapis.com',
        'calendar.googleapis.com'
    ];
    
    res.json({ success: true, message: "Enabling services..." });
    
    broadcast(`\n🛠️  Enabling Critical APIs (Compute Engine) for ${projectId}...\n`);
    
    const runEnable = (services) => new Promise((resolve) => {
        const args = ['services', 'enable', ...services, '--project', projectId];
        logger.gcloud(args);
        const cmd = spawn('gcloud', args);
        let err = '';
        cmd.stdout.on('data', d => broadcast(d.toString()));
        cmd.stderr.on('data', d => {
            const str = d.toString();
            err += str;
            broadcast(str);
        });
        cmd.on('close', (code) => resolve({ code, err }));
    });

    // 1. Enable Critical
    const critResult = await runEnable(criticalServices);
    if (critResult.code !== 0) {
        broadcast(`\n❌ CRITICAL ERROR: Failed to enable Compute Engine API.\n`);
        broadcast(`Check billing at: https://console.cloud.google.com/billing/linkedaccount?project=${projectId}\n`);
        return;
    }
    broadcast(`\n✅ Compute Engine API enabled. VM deployment is possible.\n`);

    // 2. Enable Optional
    broadcast(`\n🛠️  Enabling Bot Skill APIs (Gmail, Calendar...)\n`);
    const optResult = await runEnable(optionalServices);
    
    if (optResult.code === 0) {
        broadcast(`\n✅ All APIs enabled successfully!\n`);
    } else {
        broadcast(`\n⚠️  Warning: Some optional APIs failed to enable.\n`);
        broadcast(`Your bot will deploy, but might fail to read emails/calendars until you fix this.\n`);
        broadcast(`Visit: https://console.cloud.google.com/apis/library?project=${projectId}\n`);
    }
});

// Get VM Metrics
app.post('/api/gcp/metrics/:name', (req, res) => {
    const { name } = req.params;
    if (!isValidName(name)) {
        return res.status(400).json({ error: "Invalid name. Only alphanumeric characters and hyphens are allowed." });
    }
    const { project, zone } = req.body;

    if (!project || !zone) return res.status(400).json({ error: "Missing project/zone" });

    // Use `gcloud compute instances describe` to get status and basic info
    // For real-time CPU/RAM, we'd need Monitoring API, but let's start with instance state and static specs
    const args = [
        'compute', 'instances', 'describe', name,
        '--project', project,
        '--zone', zone,
        '--format=json(status,machineType,networkInterfaces[0].accessConfigs[0].natIP,networkInterfaces[0].networkIP,creationTimestamp,lastStartTimestamp)'
    ];
    logger.gcloud(args);
    const cmd = spawn('gcloud', args);

    let output = '';
    let err = '';
    
    cmd.stdout.on('data', d => output += d);
    cmd.stderr.on('data', d => err += d);
    
    cmd.on('close', (code) => {
        if (code !== 0) return res.status(500).json({ error: "Failed to fetch metrics", details: err });
        try {
            const data = JSON.parse(output);
            
            // Calculate uptime if running
            let uptime = null;
            if (data.status === 'RUNNING' && data.lastStartTimestamp) {
                const start = new Date(data.lastStartTimestamp);
                const now = new Date();
                const diffMs = now - start;
                // Convert to human readable "2d 4h 30m"
                const days = Math.floor(diffMs / (1000 * 60 * 60 * 24));
                const hours = Math.floor((diffMs % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
                uptime = `${days}d ${hours}h`;
            }

            res.json({
                status: data.status, // RUNNING, STOPPED, etc.
                publicIp: data.networkInterfaces?.[0]?.accessConfigs?.[0]?.natIP || 'N/A',
                internalIp: data.networkInterfaces?.[0]?.networkIP || 'N/A',
                machineType: data.machineType ? path.basename(data.machineType) : 'unknown',
                uptime: uptime || '0h',
                launchedAt: data.creationTimestamp
            });
        } catch (e) {
            res.status(500).json({ error: "Parse error" });
        }
    });
});

// --- WebSocket for Logs ---
const clients = new Set();
wss.on('connection', (ws) => {
    clients.add(ws);
    ws.on('close', () => clients.delete(ws));
    ws.send("Connected to Deployment Log Stream...\n");
});

function broadcast(msg) {
    clients.forEach(client => {
        if (client.readyState === WebSocket.OPEN) {
            client.send(msg);
        }
    });
}

// 404 Handler for API routes
app.use('/api/*', (req, res) => {
    res.status(404).json({ error: `API route not found: ${req.method} ${req.originalUrl}` });
});

const PORT = Number(process.env.CONTROL_CENTER_PORT) || 3888;
server.listen(PORT, () => {
    console.log(`Control Center running at http://localhost:${PORT}`);
});
