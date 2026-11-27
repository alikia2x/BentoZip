export type FormatCategoryId =
  | 'create-edit'
  | 'read-extract'
  | 'system-packages'
  | 'comic-splits';

export type FormatCapability =
  | 'Create'
  | 'In-Place Edit'
  | 'Rebuild Edit'
  | 'Encrypt'
  | 'Split'
  | 'Extract';

export interface ArchiveFormatSpec {
  id: string;
  name: string;
  extensions: string[];
  category: FormatCategoryId;
  capabilities: FormatCapability[];
  summary: string;
}

export const FORMAT_CATEGORIES: { id: FormatCategoryId | 'all'; label: string }[] = [
  { id: 'all', label: 'All' },
  { id: 'create-edit', label: 'Create & Edit' },
  { id: 'read-extract', label: 'Read & Extract' },
  { id: 'system-packages', label: 'Disk Images & Packages' },
  { id: 'comic-splits', label: 'Books & Splits' },
];

export const ARCHIVE_FORMAT_SPECS: ArchiveFormatSpec[] = [
  // Create & Edit
  {
    id: 'zip',
    name: 'ZIP',
    extensions: ['.zip', '.zipx'],
    category: 'create-edit',
    capabilities: ['Create', 'In-Place Edit', 'Encrypt', 'Split', 'Extract'],
    summary:
      'AES-256 or ZipCrypto encryption, multi-volume splits (10 MB–4 GB), in-place add/delete/rename, and CJK legacy filename recovery.',
  },
  {
    id: 'sevenzip',
    name: '7z',
    extensions: ['.7z'],
    category: 'create-edit',
    capabilities: ['Create', 'In-Place Edit', 'Encrypt', 'Split', 'Extract'],
    summary:
      'High-ratio LZMA2 compression with encrypted headers, multi-volume split creation, and in-place mutations for non-solid archives.',
  },
  {
    id: 'tar',
    name: 'TAR',
    extensions: ['.tar'],
    category: 'create-edit',
    capabilities: ['Create', 'In-Place Edit', 'Extract'],
    summary:
      'Standard POSIX/ustar tape archives with native in-place file addition, deletion, and renaming.',
  },
  {
    id: 'tar-gz',
    name: 'TAR.GZ',
    extensions: ['.tar.gz', '.tgz'],
    category: 'create-edit',
    capabilities: ['Create', 'Rebuild Edit', 'Extract'],
    summary:
      'Gzip-compressed tarballs with persistent LRU unwrapped caching for instant re-opening and atomic rebuild editing.',
  },
  {
    id: 'tar-bz2',
    name: 'TAR.BZ2',
    extensions: ['.tar.bz2', '.tbz', '.tbz2'],
    category: 'create-edit',
    capabilities: ['Create', 'Rebuild Edit', 'Extract'],
    summary:
      'Bzip2 tarballs with cached inner TAR browsing and atomic extract-and-rebuild modifications.',
  },
  {
    id: 'tar-xz',
    name: 'TAR.XZ',
    extensions: ['.tar.xz', '.txz'],
    category: 'create-edit',
    capabilities: ['Create', 'Rebuild Edit', 'Extract'],
    summary:
      'XZ/LZMA2 tarballs with real outer-stream progress reporting and cached instant re-open.',
  },
  {
    id: 'tar-zst',
    name: 'TAR.ZST',
    extensions: ['.tar.zst', '.tzst'],
    category: 'create-edit',
    capabilities: ['Create', 'Rebuild Edit', 'Extract'],
    summary:
      'Fast Zstandard tarballs backed by local TAR caching for responsive browsing on multi-gigabyte builds.',
  },
  {
    id: 'zst',
    name: 'Zstandard',
    extensions: ['.zst', '.zstd'],
    category: 'create-edit',
    capabilities: ['Create', 'Extract'],
    summary:
      'Single-stream Zstandard compression and decompression with automatic magic-byte container detection.',
  },
  {
    id: 'aar',
    name: 'Apple Archive',
    extensions: ['.aar', '.yaa'],
    category: 'create-edit',
    capabilities: ['Create', 'Extract'],
    summary:
      'Native macOS AppleArchive and Compression framework support for high-throughput directory archival.',
  },
  {
    id: 'dmg',
    name: 'Apple Disk Image',
    extensions: ['.dmg'],
    category: 'create-edit',
    capabilities: ['Create', 'Extract'],
    summary:
      'Create HFS+ disk images from folders or browse and extract contents of existing macOS DMG images without mounting.',
  },

  // Read & Extract
  {
    id: 'rar',
    name: 'RAR',
    extensions: ['.rar'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary:
      'Browse and extract RAR v4 and v5 archives, including password-protected containers.',
  },
  {
    id: 'gz',
    name: 'GZIP',
    extensions: ['.gz', '.gzip'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'Single-file gzip streams with automatic compound tarball unwrapping.',
  },
  {
    id: 'bz2',
    name: 'BZIP2',
    extensions: ['.bz2', '.bzip2'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'Single-file bzip2 streams and legacy Unix compressed payloads.',
  },
  {
    id: 'xz',
    name: 'XZ',
    extensions: ['.xz'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'High-ratio LZMA2 single-stream archives detected by extension or magic bytes.',
  },
  {
    id: 'lzma',
    name: 'LZMA',
    extensions: ['.lzma'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'Raw LZMA streams used in firmware images and legacy Unix bundles.',
  },
  {
    id: 'tar-lz4',
    name: 'TAR.LZ4',
    extensions: ['.tar.lz4', '.tlz4'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'Ultra-fast LZ4-framed tarballs opened directly in the Finder browser.',
  },
  {
    id: 'lz4',
    name: 'LZ4',
    extensions: ['.lz4'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'LZ4 frame payloads decoded cleanly off the main thread.',
  },
  {
    id: 'brotli',
    name: 'Brotli',
    extensions: ['.br'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'Brotli-compressed single files and web distribution assets.',
  },
  {
    id: 'cab',
    name: 'Cabinet',
    extensions: ['.cab'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'Microsoft Windows Cabinet archives inspected without third-party utilities.',
  },
  {
    id: 'cpio',
    name: 'CPIO',
    extensions: ['.cpio'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'Unix cpio archives commonly found inside initramfs images and RPM payloads.',
  },
  {
    id: 'lzh',
    name: 'LZH / LHA',
    extensions: ['.lzh', '.lha'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'Classic LHArc and LZH compressed archives from legacy distributions.',
  },
  {
    id: 'arj',
    name: 'ARJ',
    extensions: ['.arj'],
    category: 'read-extract',
    capabilities: ['Extract'],
    summary: 'Legacy DOS/Windows ARJ archives recognized by extension and magic signature.',
  },

  // System & Disk Images / Packages
  {
    id: 'iso',
    name: 'ISO 9660',
    extensions: ['.iso'],
    category: 'system-packages',
    capabilities: ['Extract'],
    summary:
      'Optical disc and OS installer images inspected directly without mounting volumes in Finder.',
  },
  {
    id: 'xar',
    name: 'XAR & macOS PKG',
    extensions: ['.xar', '.pkg'],
    category: 'system-packages',
    capabilities: ['Extract'],
    summary:
      'Inspect macOS installer packages and XAR bundles down to embedded scripts and payloads before running them.',
  },
  {
    id: 'wim',
    name: 'Windows WIM',
    extensions: ['.wim'],
    category: 'system-packages',
    capabilities: ['Extract'],
    summary: 'Windows Imaging Format containers used in OS installers and recovery images.',
  },
  {
    id: 'deb',
    name: 'Debian Package',
    extensions: ['.deb'],
    category: 'system-packages',
    capabilities: ['Extract'],
    summary: 'Browse control metadata and data tarballs inside Linux .deb packages.',
  },
  {
    id: 'rpm',
    name: 'RPM Package',
    extensions: ['.rpm'],
    category: 'system-packages',
    capabilities: ['Extract'],
    summary: 'Inspect headers and cpio payloads inside Red Hat / Fedora .rpm packages.',
  },
  {
    id: 'squashfs',
    name: 'SquashFS',
    extensions: ['.squashfs', '.sfs'],
    category: 'system-packages',
    capabilities: ['Extract'],
    summary: 'Read-only Linux compressed filesystem images used in snaps, AppImages, and firmware.',
  },
  {
    id: 'vmdk',
    name: 'VMware VMDK',
    extensions: ['.vmdk'],
    category: 'system-packages',
    capabilities: ['Extract'],
    summary: 'Inspect virtual machine disk image contents directly inside BentoZip.',
  },
  {
    id: 'chm',
    name: 'Compiled HTML',
    extensions: ['.chm'],
    category: 'system-packages',
    capabilities: ['Extract'],
    summary: 'Extract HTML pages, assets, and documentation trees from Microsoft .chm help files.',
  },

  // Books, Comics & Split Volumes
  {
    id: 'epub',
    name: 'EPUB',
    extensions: ['.epub'],
    category: 'comic-splits',
    capabilities: ['Extract'],
    summary: 'Open digital book containers to inspect chapters, stylesheets, fonts, and cover art.',
  },
  {
    id: 'cbz',
    name: 'Comic Book ZIP',
    extensions: ['.cbz'],
    category: 'comic-splits',
    capabilities: ['Create', 'In-Place Edit', 'Extract'],
    summary:
      'Browse comic pages in Grid view, preview thumbnails in the Inspector, or open the built-in Image Gallery.',
  },
  {
    id: 'cbr',
    name: 'Comic Book RAR',
    extensions: ['.cbr'],
    category: 'comic-splits',
    capabilities: ['Extract'],
    summary: 'Read RAR-backed comic archives with inline image preview and gallery browsing.',
  },
  {
    id: 'split-zip',
    name: 'Split ZIP Set',
    extensions: ['.zip.001', '.zip.002'],
    category: 'comic-splits',
    capabilities: ['Create', 'Extract'],
    summary: 'Create and extract numbered multi-volume ZIP archives across 10 MB to 4 GB parts.',
  },
  {
    id: 'split-7z',
    name: 'Split 7z Set',
    extensions: ['.7z.001', '.7z.002'],
    category: 'comic-splits',
    capabilities: ['Create', 'Extract'],
    summary: 'Create and extract multi-part 7z archives with optional header encryption.',
  },
  {
    id: 'split-rar-tar',
    name: 'Split RAR & TAR Sets',
    extensions: ['.part1.rar', '.r00', '.tar.001', '.001'],
    category: 'comic-splits',
    capabilities: ['Extract'],
    summary: 'Automatically reassemble multi-part RAR, TAR, and generic numbered volume sets.',
  },
];
