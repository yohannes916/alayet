// Default config — OVERWRITTEN at deploy time by scripts/regenerate.sh,
// which reads config/youtube-allow.txt. This file is the fallback so the
// extension still loads if regeneration hasn't run yet.
globalThis.PARENTAL_CONFIG = {
  youtubeChannels: [],   // e.g. "UC_x5XG1OV2P6uZZ5FSM9Ttw"
  youtubeVideos: [],     // e.g. "aqz-KE-bpKQ"
  youtubeHandles: [],    // e.g. "@NationalGeographic"
  restrictMode: "moderate",
};
