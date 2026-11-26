export interface FormatSpecGroup {
  id: string;
  category: string;
  formats: string[];
  description: string;
}

export const FORMAT_SPEC_GROUPS: FormatSpecGroup[] = [
  {
    id: 'create-edit',
    category: 'Create & Edit In Place',
    formats: ['ZIP', '7z', 'TAR'],
    description:
      'Create new archives, add files via drag and drop, or delete entries without rebuilding from scratch. Supports AES-256, ZipCrypto, and 7z header encryption.',
  },
  {
    id: 'compress-stream',
    category: 'Compress & Stream',
    formats: ['TAR.GZ', 'TAR.BZ2', 'TAR.XZ', 'Apple Archive (.aar)'],
    description:
      'Standard Unix tarballs and native high-speed Apple Archives with real-time progress reporting.',
  },
  {
    id: 'open-extract',
    category: 'Open & Extract',
    formats: [
      'RAR',
      'ZSTD (.zst / .tzst)',
      'GZIP',
      'BZIP2',
      'XZ',
      'LZMA',
      'CPIO',
      'LZH',
      'CAB',
    ],
    description:
      'Open downloaded packages and Linux/Windows bundles immediately without installing separate tools.',
  },
  {
    id: 'images-splits',
    category: 'Disk Images, Installers & Split Sets',
    formats: [
      'DMG',
      'ISO',
      'XAR',
      'PKG',
      'WIM',
      'DEB',
      'RPM',
      '.zip.001',
      '.7z.001',
      '.tar.001',
      '.part1.rar',
    ],
    description:
      'Peek inside macOS installers, disk images, Linux packages, and numbered split volumes directly.',
  },
];
