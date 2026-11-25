export type Lang = 'en' | 'zh';

export interface StageView {
  id: 'workspace' | 'inspector' | 'tasks' | 'welcome';
  label: string;
  image: string;
  alt: string;
  caption: string;
}

export interface SiteCopy {
  meta: {
    title: string;
    description: string;
  };
  nav: {
    features: string;
    formats: string;
    craft: string;
    download: string;
  };
  hero: {
    badge: string;
    headline: string;
    subcopy: string;
    primaryCta: string;
    secondaryCta: string;
    footnote: string;
    stages: StageView[];
  };
  bento: {
    eyebrow: string;
    title: string;
    subtitle: string;
    cards: {
      quickLook: {
        eyebrow: string;
        title: string;
        body: string;
        hintDrag: string;
        hintSpace: string;
      };
      tasks: {
        eyebrow: string;
        title: string;
        body: string;
        metrics: { label: string; value: string }[];
      };
      cache: {
        eyebrow: string;
        title: string;
        body: string;
        firstOpen: string;
        secondOpen: string;
      };
      encoding: {
        eyebrow: string;
        title: string;
        body: string;
        beforeLabel: string;
        afterLabel: string;
      };
      security: {
        eyebrow: string;
        title: string;
        body: string;
        tags: string[];
      };
    };
  };
  formatsSection: {
    eyebrow: string;
    title: string;
    subtitle: string;
    tabs: {
      all: string;
      writable: string;
      readOnly: string;
      packages: string;
    };
    badgeWritable: string;
    badgeReadOnly: string;
    badgeSplit: string;
    badgePassword: string;
  };
  craft: {
    eyebrow: string;
    title: string;
    items: {
      title: string;
      body: string;
      keys?: string[];
    }[];
  };
  closing: {
    title: string;
    subtitle: string;
    cta: string;
    meta: string;
  };
  footer: {
    tagline: string;
    releases: string;
    license: string;
    copyright: string;
  };
}

export const RELEASE_URL = 'https://github.com/alikia/BentoZip/releases/latest';
export const REPO_URL = 'https://github.com/alikia/BentoZip';

export const COPY: Record<Lang, SiteCopy> = {
  en: {
    meta: {
      title: 'BentoZip — Native macOS Archive Manager',
      description:
        'A fast, native macOS archive manager. Browse inside archives like Finder, drag out single files, press Space for Quick Look, and compress with AES-256 encryption.',
    },
    nav: {
      features: 'Features',
      formats: 'Formats',
      craft: 'Craft',
      download: 'Download',
    },
    hero: {
      badge: 'macOS 14+ / Apple Silicon',
      headline: 'Archives that feel native to macOS.',
      subcopy:
        'Browse inside archives like Finder, drag out single files, press Space for Quick Look, and pack with AES-256 encryption.',
      primaryCta: 'Download for macOS',
      secondaryCta: 'Supported Formats',
      footnote: 'Free & open source / Built for Apple Silicon on macOS 14 Sonoma and later',
      stages: [
        {
          id: 'workspace',
          label: 'Finder Browsing',
          image: '/images/hero-workspace.png',
          alt: 'BentoZip browsing a tar.gz archive in Finder-style outline view with breadcrumb path bar and inspector',
          caption:
            'Explore nested folders with Name, Date Modified, Size, Packed, and Kind columns, breadcrumb paths, and live compression ratios.',
        },
        {
          id: 'inspector',
          label: 'Pack & Split',
          image: '/images/shot-inspector.png',
          alt: 'BentoZip compression workspace with right-hand inspector showing ZIP, AES-256 encryption, and 500 MB split volumes',
          caption:
            'Configure ZIP, 7z, TAR, or Apple Archive (.aar), set AES-256 passwords, split into volumes, and exclude clutter automatically.',
        },
        {
          id: 'tasks',
          label: 'Tasks Window',
          image: '/images/shot-tasks.png',
          alt: 'BentoZip standalone Tasks window showing concurrent compression and extraction jobs with live throughput telemetry',
          caption:
            'Every compress and extract job runs in a dedicated Tasks window with elapsed time, ETA, transfer speed, and saved ratio.',
        },
        {
          id: 'welcome',
          label: 'Home & Recents',
          image: '/images/shot-welcome.png',
          alt: 'BentoZip welcome window with New Archive, Open Archive, and recent archives sidebar',
          caption:
            'Drop files to pack or archives to browse right on launch, or jump straight back into recent archives.',
        },
      ],
    },
    bento: {
      eyebrow: 'Designed for macOS',
      title: 'Everything you need before and after you click extract.',
      subtitle:
        'Built around real Finder habits instead of modal dialogs and cluttered sidebars.',
      cards: {
        quickLook: {
          eyebrow: 'Inspect Before Extracting',
          title: 'Drag out one file. Press Space for Quick Look.',
          body: 'Need a single PDF or source file from a 4 GB archive? Select it, press Space to preview right inside the window, or drag it directly onto your Desktop or Mail.',
          hintDrag: 'Drag single entries straight to Finder',
          hintSpace: 'Space to Quick Look any file',
        },
        tasks: {
          eyebrow: 'Non-Blocking Multitasking',
          title: 'Independent Tasks window',
          body: 'Keep browsing, open another window, or even close the source tab. Ongoing jobs continue in a dedicated Tasks window with live telemetry.',
          metrics: [
            { label: 'Speed', value: '184 MB/s' },
            { label: 'Remaining', value: '00:08' },
            { label: 'Saved', value: '60%' },
          ],
        },
        cache: {
          eyebrow: 'Smart Local Caching',
          title: 'Browse massive .tar.gz archives without waiting twice',
          body: 'Compressed tarballs (.tar.gz, .tar.bz2, .tar.xz, .tar.zst) are cached locally on first open so repeat browsing and single-file grabs happen almost instantly.',
          firstOpen: 'First open',
          secondOpen: 'Re-open',
        },
        encoding: {
          eyebrow: 'Legacy Archive Rescue',
          title: 'Fixes garbled filenames automatically',
          body: 'Older ZIP archives created on Windows often turn CJK filenames into unreadable symbols. BentoZip detects and restores GBK, Shift-JIS, Big5, and EUC-KR names cleanly.',
          beforeLabel: 'Raw legacy bytes',
          afterLabel: 'Restored automatically',
        },
        security: {
          eyebrow: 'Compression Inspector',
          title: 'AES-256 encryption, split volumes & Apple Archive',
          body: 'Protect ZIP and 7z archives with AES-256 passwords, split large deliveries into 10 MB to 4 GB volumes (.001), edit existing ZIP/7z/TAR archives in place, or create native Apple Archive (.aar) packages.',
          tags: ['AES-256', 'Split Volumes (.001)', 'In-Place Edit', 'Apple Archive (.aar)'],
        },
      },
    },
    formatsSection: {
      eyebrow: '28 Formats Supported',
      title: 'One calm window for every archive on your Mac.',
      subtitle:
        'Create and edit everyday archives in place, or open multi-part packages, Windows installers, and macOS disk images without mounting.',
      tabs: {
        all: 'All (28)',
        writable: 'Create & Edit (7)',
        readOnly: 'Read & Extract (14)',
        packages: 'Disk Images & Packages (7)',
      },
      badgeWritable: 'Create & Edit',
      badgeReadOnly: 'Read Only',
      badgeSplit: 'Multi-Volume',
      badgePassword: 'Encrypted',
    },
    craft: {
      eyebrow: 'Quiet Details',
      title: 'Sweat the small things Finder users notice.',
      items: [
        {
          title: 'Finder keyboard flow',
          body: 'Arrow through folders, press Space for Quick Look, Command+Down to enter a folder, and Command+Up to step back.',
          keys: ['Space', '⌘↓', '⌘↑', '⌫'],
        },
        {
          title: 'True document windows',
          body: 'Titlebar proxy icons let you drag or reveal the open archive in Finder, while opening the same file brings its existing window forward.',
        },
        {
          title: 'Clean archives by default',
          body: 'Automatically skips .DS_Store and __MACOSX metadata when packing, with custom glob exclusion rules saved per preset.',
        },
        {
          title: 'Smart single-folder unwrap',
          body: 'Avoids double-nested folders on extraction when an archive already wraps everything inside a single top directory.',
        },
      ],
    },
    closing: {
      title: 'Ready for cleaner archives on macOS.',
      subtitle: 'Download BentoZip and keep every ZIP, 7z, RAR, and tarball right at home.',
      cta: 'Download for macOS',
      meta: 'macOS 14 Sonoma or later / Apple Silicon',
    },
    footer: {
      tagline: 'Native macOS archive manager.',
      releases: 'Releases',
      license: 'GitHub',
      copyright: '© 2026 BentoZip',
    },
  },

  zh: {
    meta: {
      title: 'BentoZip — 天生像访达一样轻快的 macOS 压缩工具',
      description:
        '原生 macOS 归档与解压工具。像浏览访达一样查看压缩包内部、直接拖出单个文件、按空格键快速预览，并支持 AES-256 加密与分卷压缩。',
    },
    nav: {
      features: '功能特性',
      formats: '支持格式',
      craft: '细节打磨',
      download: '下载',
    },
    hero: {
      badge: 'macOS 14+ / Apple Silicon 原生',
      headline: '天生像访达一样轻快的 macOS 压缩工具',
      subcopy:
        '像浏览访达一样查看压缩包内部，支持直接拖出单个文件、空格键快速预览、AES-256 加密与独立任务窗口。',
      primaryCta: '下载 macOS 版',
      secondaryCta: '查看支持格式',
      footnote: '免费开源 / 适配 Apple Silicon，支持 macOS 14 Sonoma 及以上系统',
      stages: [
        {
          id: 'workspace',
          label: '访达式浏览',
          image: '/images/hero-workspace.png',
          alt: 'BentoZip 以访达风格大纲视图浏览 tar.gz 压缩包，带有路径栏与右侧检查器',
          caption:
            '提供名称、修改日期、大小、压缩后大小与种类列，配合底部路径栏与实时压缩率统计，翻找文件无需全部解压。',
        },
        {
          id: 'inspector',
          label: '打包与分卷',
          image: '/images/shot-inspector.png',
          alt: 'BentoZip 压缩工作区与右侧检查器，支持 ZIP、AES-256 加密与 500 MB 分卷压缩',
          caption:
            '可自由切换 ZIP、7z、TAR 或 Apple Archive (.aar)，设置 AES-256 密码、分卷大小并自动排除系统冗余文件。',
        },
        {
          id: 'tasks',
          label: '独立任务窗口',
          image: '/images/shot-tasks.png',
          alt: 'BentoZip 独立任务窗口展示并发压缩与解压任务及实时吞吐量数据',
          caption:
            '所有压缩与解压任务都在独立的任务窗口中并行运转，实时显示已用时间、剩余时间、速度与压缩率。',
        },
        {
          id: 'welcome',
          label: '欢迎页与最近打开',
          image: '/images/shot-welcome.png',
          alt: 'BentoZip 欢迎窗口展示新建压缩包、打开压缩包与最近打开列表',
          caption:
            '启动即可直接拖入文件打包或拖入压缩包浏览，右侧最近打开列表让常用归档触手可及。',
        },
      ],
    },
    bento: {
      eyebrow: '为 macOS 原生打造',
      title: '解压之前与打包之后，每一步都恰到好处。',
      subtitle: '贴合访达操作习惯，告别层层弹窗与臃肿侧边栏。',
      cards: {
        quickLook: {
          eyebrow: '先预览，再决定',
          title: '单个文件直接拖出，按空格键快速预览',
          body: '只想从 4 GB 大包里拿出一份 PDF 或代码文件？选中后按空格键即可直接快速查看，或把它直接拖到桌面与邮件窗口。',
          hintDrag: '单个条目直接拖进访达',
          hintSpace: '按空格键即时快速查看',
        },
        tasks: {
          eyebrow: '不阻塞的多任务体验',
          title: '独立任务窗口',
          body: '压缩或解压进行时，你可以继续浏览当前目录、打开其他窗口，甚至直接关闭原文档窗口，任务仍会在独立窗口稳步完成。',
          metrics: [
            { label: '当前速度', value: '184 MB/s' },
            { label: '预计剩余', value: '00:08' },
            { label: '节省空间', value: '60%' },
          ],
        },
        cache: {
          eyebrow: '智能本地缓存',
          title: '大型 .tar.gz 压缩包二次打开无需等待',
          body: '首次打开大型 .tar.gz、.tar.bz2、.tar.xz 或 .tar.zst 归档后会在本地保留可配置上限的缓存，再次浏览或提取单文件近乎瞬开。',
          firstOpen: '首次打开',
          secondOpen: '再次打开',
        },
        encoding: {
          eyebrow: '老旧压缩包乱码修复',
          title: '自动还原中文日文韩文乱码文件名',
          body: '早期 Windows 环境打包的 ZIP 在 Mac 上常出现文件名乱码。BentoZip 会自动识别并修复 GBK、Shift-JIS、Big5 与 EUC-KR 编码。',
          beforeLabel: '原始乱码文件名',
          afterLabel: '自动修复还原',
        },
        security: {
          eyebrow: '右侧检查器',
          title: 'AES-256 加密、分卷压缩与 Apple Archive',
          body: '为 ZIP 与 7z 设置 AES-256 密码，按 10 MB 至 4 GB 切分多卷压缩包，就地增删已有归档条目，或创建原生 .aar 格式。',
          tags: ['AES-256 加密', '多卷切分 (.001)', '就地增删条目', 'Apple Archive (.aar)'],
        },
      },
    },
    formatsSection: {
      eyebrow: '支持 28 种归档格式',
      title: 'Mac 上常见的压缩包与镜像，一个窗口搞定。',
      subtitle: '常用格式支持创建与就地增删，多卷压缩包、系统镜像与各类安装包无需挂载即可直接浏览并解压。',
      tabs: {
        all: '全部 (28)',
        writable: '创建与编辑 (7)',
        readOnly: '读取与解压 (14)',
        packages: '磁盘镜像与安装包 (7)',
      },
      badgeWritable: '支持创建与编辑',
      badgeReadOnly: '只读解压',
      badgeSplit: '多卷归档',
      badgePassword: '支持加密',
    },
    craft: {
      eyebrow: '克制而周到的细节',
      title: '把访达用户每天都会用到的习惯做扎实。',
      items: [
        {
          title: '访达级键盘导航',
          body: '方向键浏览目录，空格键快速查看，Command+Down 进入文件夹，Command+Up 返回上一级，Delete 键移除条目。',
          keys: ['Space', '⌘↓', '⌘↑', '⌫'],
        },
        {
          title: '原生文档窗口体验',
          body: '标题栏支持文件代理图标拖拽与在访达中定位，重复打开同一个压缩包时会自动前置已有窗口。',
        },
        {
          title: '默认输出干净归档',
          body: '打包时自动过滤 .DS_Store 与 __MACOSX 等系统隐藏文件，并支持将自定义排除规则存为默认配置。',
        },
        {
          title: '智能剥离单层顶目录',
          body: '当压缩包内只包含一个顶层文件夹时，解压可自动避免多套一层同名目录。',
        },
      ],
    },
    closing: {
      title: '给你的 Mac 换上一款更顺手的压缩工具',
      subtitle: '下载 BentoZip，让 ZIP、7z、RAR 与各类源码压缩包融入原生的 macOS 体验。',
      cta: '下载 macOS 版',
      meta: '支持 macOS 14 Sonoma 及以上 / Apple Silicon 原生',
    },
    footer: {
      tagline: '原生 macOS 归档与压缩管理器',
      releases: '版本发布',
      license: 'GitHub',
      copyright: '© 2026 BentoZip',
    },
  },
};
