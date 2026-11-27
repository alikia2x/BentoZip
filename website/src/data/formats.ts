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
    summary:
      'Build clean archives, Apple Archives, and compressed disk images, or edit ZIP, 7z, and TAR contents in place with strong encryption.',
  },
  {
    id: 'read-extract',
    category: 'Read & Extract',
    formatsText: 'RAR, Zstd (.zst), GZIP, BZ2, XZ, LZ4, Brotli, LZMA, CPIO, LZH, CAB, ARJ',
    summary:
      'Open downloaded bundles and compressed streams right away in one consistent browser.',
  },
  {
    id: 'disk-images',
    category: 'Disk & System Images',
    formatsText: 'ISO, WIM, SquashFS, VMDK, CHM',
    summary:
      'Browse and pull out individual files from optical disc images, Windows backups, Linux filesystems, virtual disks, and help books.',
  },
  {
    id: 'comics-packages-splits',
    category: 'Comics, Packages & Splits',
    formatsText:
      'CBZ, CBR, EPUB, XAR, PKG, DEB, RPM, .zip.001, .7z.001, .tar.001, .part1.rar',
    summary:
      'Flip through comics in a full gallery, inspect macOS installers and Linux packages, or handle numbered split volumes.',
  },
];
