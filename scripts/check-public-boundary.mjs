import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const forbiddenExtensions = new Set([
  ".rbxl", ".rbxlx", ".rbxm", ".rbxmx", ".fbx", ".gltf", ".glb", ".obj",
  ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".wav", ".mp3",
  ".ogg", ".flac", ".mp4", ".mov", ".ttf", ".otf",
]);
const forbiddenPathParts = new Set([
  "assets", "content", "lobby", "loading", "gui", "hud", "commerce",
  "profile", "evidence", ".reference",
]);
const forbiddenText = [
  [/RobloxArena|Roblox Arena/g, "private codename"],
  [/rbxassetid:\/\/\d+/g, "Roblox asset ID"],
  [/servePlaceIds|game\.PlaceId\s*==\s*\d+/g, "Roblox place ID"],
  [/sharedRoot[.:](?:commerce|presentation|content|profile|settings|matchmaking)\b/g, "private game-module dependency"],
  [/(?:aerowalk|blood[_ ]?run|dm17|terminatria|trespass|xtreme[_ ]?force|corrosion|achromatic|all[_ ]?the[_ ]?aces|bad[_ ]?ball|evil[_ ]?gemini|theatre[_ ]?of[_ ]?pain|in[_ ]?perfect[_ ]?harmony)/gi, "authored map identifier"],
  [/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g, "private key"],
];
const ignoredDirectories = new Set([".git", "node_modules", "build"]);
const violations = [];

function visit(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (ignoredDirectories.has(entry.name)) continue;
    const absolute = path.join(directory, entry.name);
    const relative = path.relative(root, absolute);
    if (entry.isDirectory()) {
      if (relative.split(path.sep).some((part) => forbiddenPathParts.has(part.toLowerCase()))) {
        violations.push(`${relative}: forbidden content directory`);
      }
      visit(absolute);
      continue;
    }
    if (forbiddenExtensions.has(path.extname(entry.name).toLowerCase())) {
      violations.push(`${relative}: forbidden asset/project extension`);
      continue;
    }
    if (entry.name === ".env" || entry.name.startsWith(".env.")) {
      violations.push(`${relative}: secret environment file`);
      continue;
    }
    if (relative === path.join("scripts", "check-public-boundary.mjs")) continue;
    const text = fs.readFileSync(absolute, "utf8");
    for (const [pattern, label] of forbiddenText) {
      pattern.lastIndex = 0;
      if (pattern.test(text)) violations.push(`${relative}: contains ${label}`);
    }
  }
}

visit(root);
if (violations.length > 0) {
  console.error(violations.join("\n"));
  process.exit(1);
}
console.log("Public repository boundary check passed.");
