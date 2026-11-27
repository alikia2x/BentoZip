export interface FormatDirectoryGroup {
  id: string;
  category: string;
  formatsText: string;
  summary: string;
}

export const FORMAT_DIRECTORY_GROUPS: FormatDirectoryGroup[] = [
  {
    id: 'create-edit',
    category: 'Create & Edit',
    formatsText: 'ZIP, 7z, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, TAR.ZST, AAR, DMG',
    summary: 'Create encrypted archives and disk images, or edit ZIP, 7z, and TAR contents in place.',
  },
  {
    id: 'read-extract',
    category: 'Read & Extract',
    formatsText: 'RAR, Zstd (.zst), GZIP, BZ2, XZ, LZ4, Brotli, LZMA, CPIO, LZH, CAB, ARJ',
    summary: 'Open downloaded archives and compressed streams in one browser.',
  },
  {
    id: 'disk-images',
    category: 'Disk & System Images',
    formatsText: 'ISO, WIM, SquashFS, VMDK, CHM',
    summary: 'Inspect disc images, Windows backups, virtual disks, and help books.',
  },
  {
    id: 'comics-packages-splits',
    category: 'Comics, Packages & Splits',
    formatsText: 'CBZ, CBR, EPUB, XAR, PKG, DEB, RPM, .zip.001, .7z.001, .tar.001, .part1.rar',
    summary: 'Read comic bundles, inspect installer packages, and unpack multi-part archives.',
  },
];
