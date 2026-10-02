// Renders the app icon from the Chrome extension's three-bar mark
// (../focused-spotify/scripts/icons.mjs): same bar positions, heights and
// colors, but full-bleed and 1024 px, because iOS applies its own corner
// mask. Supersampled 4x per pixel so the rounded bar ends stay smooth.
//
//   node scripts/make-icon.mjs
import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';

const SIZE = 1024, SS = 4;
const OUT = 'Focused/Assets.xcassets/AppIcon.appiconset';

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const body = Buffer.concat([Buffer.from(type), data]);
  const size = Buffer.alloc(4); size.writeUInt32BE(data.length);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
  return Buffer.concat([size, body, crc]);
}
function inBar(nx, ny) {
  return [[.3, .32], [.5, .5], [.7, .32]].some(([center, height]) => {
    const dy = Math.max(Math.abs(ny - .5) - height / 2 + .045, 0);
    return Math.hypot(nx - center, dy) <= .045;
  });
}
function render(file, background, bar) {
  const raw = Buffer.alloc(SIZE * (SIZE * 3 + 1));
  for (let y = 0; y < SIZE; y++) for (let x = 0; x < SIZE; x++) {
    let hits = 0;
    for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
      if (inBar((x + (sx + .5) / SS) / SIZE, (y + (sy + .5) / SS) / SIZE)) hits++;
    }
    const t = hits / (SS * SS);
    const pixel = y * (SIZE * 3 + 1) + 1 + x * 3;
    for (let c = 0; c < 3; c++) raw[pixel + c] = Math.round(background[c] + (bar[c] - background[c]) * t);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(SIZE, 0); header.writeUInt32BE(SIZE, 4); header[8] = 8; header[9] = 2;
  writeFileSync(`${OUT}/${file}`, Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', header), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
  ]));
}
render('AppIcon.png', [23, 32, 26], [194, 239, 206]);
// Dark home-screen appearance: near-black ground, same mint bars.
render('AppIcon-Dark.png', [10, 14, 11], [194, 239, 206]);
console.log('Generated app icons.');
