import React, { useEffect, useState } from 'react';
import { ArrowUpRight, Check, Copy, Download, Terminal } from 'lucide-react';

interface GitHubAsset {
  name: string;
  browser_download_url: string;
  size: number;
}

interface GitHubRelease {
  tag_name: string;
  html_url: string;
  published_at?: string;
  assets?: GitHubAsset[];
}

interface ReleaseState {
  version: string;
  dmgUrl: string;
  dmgSizeLabel: string | null;
  zipUrl: string | null;
  releasePageUrl: string;
  loaded: boolean;
}

const REPO_URL = 'https://github.com/alikia2x/BentoZip';
const FALLBACK_RELEASES_URL = 'https://github.com/alikia2x/BentoZip/releases/latest';
const API_URL = 'https://api.github.com/repos/alikia2x/BentoZip/releases/latest';

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '';
  const mb = bytes / (1024 * 1024);
  return `${mb.toFixed(1)} MB`;
}

interface DownloadWidgetProps {
  variant?: 'hero' | 'compact';
}

export default function DownloadWidget({ variant = 'hero' }: DownloadWidgetProps) {
  const [release, setRelease] = useState<ReleaseState>({
    version: 'v1.0.1',
    dmgUrl: FALLBACK_RELEASES_URL,
    dmgSizeLabel: null,
    zipUrl: null,
    releasePageUrl: FALLBACK_RELEASES_URL,
    loaded: false,
  });
  const [copiedCli, setCopiedCli] = useState(false);

  useEffect(() => {
    const controller = new AbortController();

    fetch(API_URL, {
      headers: { Accept: 'application/vnd.github+json' },
      signal: controller.signal,
    })
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        return res.json() as Promise<GitHubRelease>;
      })
      .then((data) => {
        const assets = data.assets ?? [];
        const dmg = assets.find((asset) => asset.name.toLowerCase().endsWith('.dmg'));
        const zip = assets.find((asset) => asset.name.toLowerCase().endsWith('.zip'));

        setRelease({
          version: data.tag_name || 'v1.0.0',
          dmgUrl: dmg?.browser_download_url || data.html_url || FALLBACK_RELEASES_URL,
          dmgSizeLabel: dmg ? formatBytes(dmg.size) : null,
          zipUrl: zip?.browser_download_url ?? null,
          releasePageUrl: data.html_url || FALLBACK_RELEASES_URL,
          loaded: true,
        });
      })
      .catch(() => {
        // Keep clean SSR fallback links silently on rate-limit or offline environments
      });

    return () => controller.abort();
  }, []);

  const handleCopyCli = async () => {
    try {
      await navigator.clipboard.writeText('bentozip open archive.zip');
      setCopiedCli(true);
      window.setTimeout(() => setCopiedCli(false), 1800);
    } catch {
      // Clipboard unavailable
    }
  };

  if (variant === 'compact') {
    return (
      <div className="flex flex-col items-center gap-4">
        <div className="flex flex-wrap items-center justify-center gap-3">
          <a
            href={release.dmgUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-2.5 h-12 px-7 rounded-full bg-[#0A84FF] hover:bg-[#1E8FFF] text-white text-[15px] font-medium tracking-[-0.01em] shadow-[0_10px_30px_rgba(10,132,255,0.35)] transition-all"
          >
            <Download className="w-4 h-4" />
            <span>
              Download DMG
              {release.loaded && release.dmgSizeLabel ? ` · ${release.dmgSizeLabel}` : ''}
            </span>
          </a>

          <a
            href={REPO_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1.5 h-12 px-5 rounded-full bg-white/[0.06] hover:bg-white/[0.1] border border-white/[0.12] text-white text-[14.5px] font-medium transition-colors"
          >
            <span>GitHub</span>
            <ArrowUpRight className="w-4 h-4 text-[#A1A1A6]" />
          </a>
        </div>

        <p className="text-[12.5px] text-[#8E8E93] font-mono tabular-nums">
          {release.version} · Universal (Apple Silicon &amp; Intel) · macOS 14.0+ · Signed &amp; Notarized
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-col items-center max-w-full">
      <div className="inline-flex flex-wrap items-center justify-center gap-2 px-3 py-1 rounded-full bg-white/[0.05] border border-white/[0.1] text-[12px] text-[#D1D1D6] font-mono mb-6 max-w-full">
        <span className="w-1.5 h-1.5 rounded-full bg-[#30D158]" aria-hidden="true" />
        <span>{release.version}</span>
        <span className="text-white/25" aria-hidden="true">/</span>
        <span>Universal arm64 + x86_64</span>
        <span className="hidden sm:inline text-white/25" aria-hidden="true">/</span>
        <span className="hidden sm:inline">macOS 14+</span>
      </div>

      <div className="flex flex-wrap items-center justify-center gap-3.5">
        <a
          href={release.dmgUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-2.5 h-12 px-7 rounded-full bg-[#0A84FF] hover:bg-[#1E8FFF] text-white text-[15px] font-medium tracking-[-0.01em] shadow-[0_12px_32px_rgba(10,132,255,0.32)] transition-all"
        >
          <Download className="w-4 h-4" />
          <span>
            Download for macOS
            {release.dmgSizeLabel ? ` (${release.dmgSizeLabel})` : ''}
          </span>
        </a>

        <a
          href={REPO_URL}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-2 h-12 px-6 rounded-full bg-white/[0.06] hover:bg-white/[0.1] border border-white/[0.12] text-[#F5F5F7] text-[15px] font-medium tracking-[-0.01em] transition-colors"
        >
          <span>View Source</span>
          <ArrowUpRight className="w-4 h-4 text-[#A1A1A6]" />
        </a>
      </div>

      <div className="mt-5 flex flex-wrap items-center justify-center gap-x-4 gap-y-2 text-[12.5px] text-[#8E8E93]">
        <a
          href={release.releasePageUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="hover:text-white transition-colors underline decoration-white/20 underline-offset-4"
        >
          Release notes &amp; SHA-256
        </a>
        {release.zipUrl && (
          <>
            <span className="text-white/20" aria-hidden="true">·</span>
            <a
              href={release.zipUrl}
              target="_blank"
              rel="noopener noreferrer"
              className="hover:text-white transition-colors"
            >
              Direct .zip bundle
            </a>
          </>
        )}
        <span className="text-white/20" aria-hidden="true">·</span>
        <button
          type="button"
          onClick={handleCopyCli}
          className="inline-flex items-center gap-1.5 font-mono text-[12px] text-[#A1A1A6] hover:text-white transition-colors cursor-pointer"
          title="Copy CLI example (installed via Settings)"
        >
          <Terminal className="w-3.5 h-3.5 text-[#0A84FF]" />
          <span>bentozip open archive.zip</span>
          {copiedCli ? (
            <Check className="w-3.5 h-3.5 text-[#30D158]" />
          ) : (
            <Copy className="w-3 h-3 opacity-60" />
          )}
        </button>
      </div>
    </div>
  );
}
