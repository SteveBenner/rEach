# frozen_string_literal: true

require "cgi"

module Figures
  SANS = "Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif"
  MONO = "ui-monospace,'SF Mono',Menlo,Consolas,'Liberation Mono',monospace"

  THEMES = {
    "dark" => {
      bg0: "#1a2331", bg1: "#0e131c", bg2: "#07090d",
      panel: "#121925", panel2: "#19222f", line: "#2e3949",
      ink: "#f3f5f8", soft: "#b3bdca", faint: "#6f7b8c",
      student: "#f7a928", student2: "#fb7185", reach: "#38bdf8",
      teach: "#d5dce6", instructor: "#b79cff", ok: "#34d399", stop: "#f87171",
      frost: "#dfe7f1", frost_op: 0.075, zone: "#0f151f", zone_op: 0.62,
      blob_op: 0.2, hatch_op: 0.05, deco_op: 0.07, tint: 0.11, shadow: 0.45
    },
    "light" => {
      bg0: "#ffffff", bg1: "#f6f8fb", bg2: "#edf1f6",
      panel: "#ffffff", panel2: "#f3f6fa", line: "#d3dae4",
      ink: "#111823", soft: "#465264", faint: "#8490a1",
      student: "#b45309", student2: "#be123c", reach: "#0369a1",
      teach: "#64748b", instructor: "#6d28d9", ok: "#047857", stop: "#b91c1c",
      frost: "#8fa0b6", frost_op: 0.16, zone: "#ffffff", zone_op: 0.78,
      blob_op: 0.12, hatch_op: 0.07, deco_op: 0.5, tint: 0.07, shadow: 0.1
    }
  }.freeze

  TONES = %i[student reach teach instructor ok stop soft].freeze

  ICONS = {
    person: "M12 12.5a4.2 4.2 0 1 0 0-8.4 4.2 4.2 0 0 0 0 8.4ZM4 21c.6-4.2 3.8-6.3 8-6.3s7.4 2.1 8 6.3",
    agent: "M7 8h10a2 2 0 0 1 2 2v7a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2ZM12 8V4.5M9.2 13v1.6M14.8 13v1.6M2.5 12.5v3M21.5 12.5v3",
    lock: "M7 11V8a5 5 0 0 1 10 0v3M6 11h12a1 1 0 0 1 1 1v7a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1ZM12 15v2",
    shield: "M12 3l8 3v6c0 4.6-3.2 8-8 9.5C7.2 20 4 16.6 4 12V6l8-3ZM8.8 12l2.3 2.3 4.3-4.6",
    key: "M14.5 9.5a4 4 0 1 0-3.7 4L3.5 20.8V21h3v-2h2v-2h2l2.2-2.2a4 4 0 0 0 1.8-5.3ZM16.5 7.5h.01",
    doc: "M7 3h7l5 5v12a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1ZM14 3v5h5M9 13h6M9 17h6",
    check: "M5 12.5l4.5 4.5L19 7.5",
    cross: "M6 6l12 12M18 6L6 18",
    server: "M5 4h14a1 1 0 0 1 1 1v5H4V5a1 1 0 0 1 1-1ZM4 10h16v5H4zM4 15h16v4a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-4ZM7.5 7h.01M7.5 12.5h.01M7.5 17.5h.01",
    cloud: "M7 18.5a4.5 4.5 0 0 1-.6-8.96A6 6 0 0 1 18 10.5a4 4 0 0 1-.5 8H7Z",
    hand: "M8 12V5.5a1.5 1.5 0 0 1 3 0V11M11 10.5V4a1.5 1.5 0 0 1 3 0v6.5M14 10.5V5.5a1.5 1.5 0 0 1 3 0V13M17 11.5a1.5 1.5 0 0 1 3 0V15a6 6 0 0 1-6 6h-1.5a6 6 0 0 1-5-2.7L4.3 13.5a1.5 1.5 0 0 1 2.5-1.6L8 13.5",
    eye_off: "M3 3l18 18M10.6 6.2A9.500 9.5 0 0 1 12 6c5 0 8.5 4 9.5 6a13 13 0 0 1-2.8 3.6M6.3 7.8A13 13 0 0 0 2.5 12c1 2 4.5 6 9.5 6a9 9 0 0 0 3.6-.8M9.9 9.9a3 3 0 0 0 4.2 4.2",
    folder: "M3 7a1 1 0 0 1 1-1h5l2 2.5h9a1 1 0 0 1 1 1V18a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V7Z",
    box: "M12 3l8 4.5v9L12 21l-8-4.5v-9L12 3ZM4 7.5l8 4.5 8-4.5M12 12v9",
    receipt: "M6 3h12v18l-3-2-3 2-3-2-3 2V3ZM9 8h6M9 12h6",
    loop: "M4 12a8 8 0 0 1 13.7-5.6L20 8.5M20 4v4.5h-4.5M20 12a8 8 0 0 1-13.7 5.6L4 15.5M4 20v-4.5h4.5",
    board: "M4 5h16v11H4zM9 20h6M12 16v4M7.5 12l3-3 2.5 2 3.5-3.5",
    brain: "M9.5 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 5.5 1V5.5A2.5 2.5 0 0 0 9.5 4ZM14.5 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-5.5 1",
    seal: "M12 3l2.2 2 3-.3.7 2.9 2.6 1.5-1.200 2.7 1.200 2.7-2.6 1.5-.7 2.9-3-.3L12 21l-2.2-2-3 .3-.7-2.9-2.6-1.5L4.7 12 3.5 9.3l2.6-1.500.7-2.9 3 .3L12 3ZM9 12l2 2 4-4.2"
  }.freeze

  class Canvas
    attr_reader :w, :h, :theme, :name

    def initialize(width, height, theme_name, title:, desc:)
      @w = width
      @h = height
      @name = theme_name
      @theme = THEMES.fetch(theme_name)
      @title = title
      @desc = desc
      @out = []
      @defs = []
      @seq = 0
      base_defs
      background
    end

    def dark?
      @name == "dark"
    end

    def c(key)
      key.is_a?(Symbol) ? @theme.fetch(key) : key
    end

    def e(str)
      CGI.escapeHTML(str.to_s)
    end

    def uid(prefix)
      @seq += 1
      "#{prefix}#{@seq}"
    end

    def raw(svg)
      @out << svg
      self
    end

    def tw(str, size, mono: false, weight: 400)
      factor = mono ? 0.602 : (weight >= 600 ? 0.565 : 0.525)
      str.to_s.length * size * factor
    end

    def rect(x, y, width, height, rx: 0, fill: "none", stroke: nil, sw: 1.5, fo: nil, so: nil, dash: nil, extra: "")
      a = %(<rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" rx="#{rx}" fill="#{c(fill)}")
      a += %( fill-opacity="#{fo}") if fo
      a += %( stroke="#{c(stroke)}" stroke-width="#{sw}") if stroke
      a += %( stroke-opacity="#{so}") if so
      a += %( stroke-dasharray="#{dash}") if dash
      raw("#{a} #{extra}/>")
    end

    def line(x1, y1, x2, y2, stroke: :line, sw: 1.5, so: nil, dash: nil)
      a = %(<line x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}" stroke="#{c(stroke)}" stroke-width="#{sw}" stroke-linecap="round")
      a += %( stroke-opacity="#{so}") if so
      a += %( stroke-dasharray="#{dash}") if dash
      raw("#{a}/>")
    end

    def circle(cx, cy, r, fill: "none", stroke: nil, sw: 1.5, fo: nil, so: nil, dash: nil)
      a = %(<circle cx="#{cx}" cy="#{cy}" r="#{r}" fill="#{c(fill)}")
      a += %( fill-opacity="#{fo}") if fo
      a += %( stroke="#{c(stroke)}" stroke-width="#{sw}") if stroke
      a += %( stroke-opacity="#{so}") if so
      a += %( stroke-dasharray="#{dash}") if dash
      raw("#{a}/>")
    end

    def text(x, y, str, size: 18, weight: 400, fill: :ink, anchor: "start", mono: false, spacing: nil, opacity: nil, halo: false, italic: false)
      a = %(<text x="#{x}" y="#{y}" font-family="#{mono ? MONO : SANS}" font-size="#{size}" font-weight="#{weight}" fill="#{c(fill)}" text-anchor="#{anchor}")
      a += %( letter-spacing="#{spacing}") if spacing
      a += %( fill-opacity="#{opacity}") if opacity
      a += %( font-style="italic") if italic
      a += %( paint-order="stroke" stroke="#{c(:bg1)}" stroke-width="#{(size * 0.42).round(1)}" stroke-linejoin="round") if halo
      raw("#{a}>#{e(str)}</text>")
    end

    def lines(x, y, strs, size: 17, lh: nil, **opts)
      lh ||= (size * 1.42).round
      Array(strs).each_with_index { |s, i| text(x, y + i * lh, s, size: size, **opts) }
      y + Array(strs).length * lh
    end

    def wrap(str, chars)
      str.to_s.scan(/\S.{0,#{chars - 1}}(?=\s|$)|\S+/)
    end

    def para(x, y, str, chars, **opts)
      lines(x, y, wrap(str, chars), **opts)
    end

    def group(tx, ty, scale = 1)
      raw(%(<g transform="translate(#{tx} #{ty}) scale(#{scale})">))
      yield
      raw("</g>")
    end

    def bullets(x, y, items, tone: :reach, size: 16, gap: 34, fill: :soft)
      items.each_with_index do |item, i|
        circle(x + 5, y + i * gap - size * 0.32, 3.5, fill: tone)
        text(x + 20, y + i * gap, item, size: size, fill: fill)
      end
      y + items.length * gap
    end

    def level(cx, cy, kind, r: 11)
      case kind
      when :full
        circle(cx, cy, r, fill: :ok)
        icon(:check, cx, cy, r * 1.25, dark? ? "#0b0f16" : "#ffffff", sw: 2.6)
      when :part
        circle(cx, cy, r, fill: :student, fo: 0.18, stroke: :student, sw: 2)
        raw(%(<path d="M#{cx} #{cy - r}A#{r} #{r} 0 0 0 #{cx} #{cy + r}Z" fill="#{c(:student)}"/>))
      when :deny
        circle(cx, cy, r, fill: :stop, fo: 0.16, stroke: :stop, sw: 2)
        icon(:cross, cx, cy, r * 1.1, :stop, sw: 2.4)
      else
        circle(cx, cy, r, stroke: :faint, sw: 2)
      end
    end

    def icon(name, cx, cy, size, tone = :ink, sw: 1.7)
      s = size / 24.0
      move = "translate(#{(cx - size / 2.0).round(2)} #{(cy - size / 2.0).round(2)}) scale(#{s.round(4)})"
      raw(%(<path transform="#{move}" d="#{ICONS.fetch(name)}" fill="none" stroke="#{c(tone)}" stroke-width="#{(sw / s).round(2)}" stroke-linecap="round" stroke-linejoin="round"/>))
    end

    def badge(cx, cy, size, name, tone)
      circle(cx, cy, size * 0.82, fill: tone, fo: @theme[:tint] * 1.5, stroke: tone, sw: 1.5, so: 0.7)
      icon(name, cx, cy, size, tone)
    end

    def num(cx, cy, n, tone = :reach, r: 17)
      circle(cx, cy, r, fill: tone)
      text(cx, cy + r * 0.36, n, size: (r * 1.05).round, weight: 700, fill: dark? ? "#0b0f16" : "#ffffff", anchor: "middle")
    end

    def pill(x, y, str, tone: :reach, mono: false, size: 15, weight: 600, filled: false, anchor: "start")
      width = (tw(str, size, mono: mono, weight: weight) + size * 1.5).round
      height = (size * 1.9).round
      x -= width / 2.0 if anchor == "middle"
      x -= width if anchor == "end"
      if filled
        rect(x, y, width, height, rx: height / 2.0, fill: tone)
        text(x + width / 2.0, y + height * 0.68, str, size: size, weight: weight, mono: mono, anchor: "middle", fill: dark? ? "#0b0f16" : "#ffffff")
      else
        rect(x, y, width, height, rx: height / 2.0, fill: :bg1)
        rect(x, y, width, height, rx: height / 2.0, fill: tone, fo: @theme[:tint] * 1.3, stroke: tone, sw: 1.2, so: 0.65)
        text(x + width / 2.0, y + height * 0.68, str, size: size, weight: weight, mono: mono, anchor: "middle", fill: tone)
      end
      width
    end

    def card(x, y, width, height, tone: :reach, title: nil, body: [], icon: nil, tag: nil, title_size: 21, body_size: 16, pad: 22, accent: true, solid: false)
      rect(x, y + 6, width, height, rx: 18, fill: "#000000", fo: @theme[:shadow] * 0.5, extra: %(filter="url(#soft)"))
      rect(x, y, width, height, rx: 18, fill: :panel)
      rect(x, y, width, height, rx: 18, fill: tone, fo: solid ? @theme[:tint] * 1.6 : @theme[:tint] * 0.55, stroke: tone, sw: 1.5, so: 0.6)
      rect(x + 1.5, y + 22, 4, [height - 44, 12].max, rx: 2, fill: tone, fo: 0.9) if accent
      tx = x + pad
      ty = y + pad + title_size * 0.82
      if icon
        badge(x + pad + 17, y + pad + 15, 22, icon, tone)
        tx += 46
        ty = y + pad + 22
      end
      text(tx, ty, title, size: title_size, weight: 650, fill: :ink) if title
      by = (title ? ty + body_size * 1.75 : y + pad + body_size).round
      by = [by, y + pad + 56].max if icon && title
      lines(x + pad, by, body, size: body_size, fill: :soft)
      pill(x + width - pad, y + height - pad - 26, tag, tone: tone, mono: true, size: 13, weight: 500, anchor: "end") if tag
      self
    end

    def arrow(pts, tone: :reach, label: nil, at: nil, dashed: false, both: false, sw: 2.4, size: 15, mono: false, anchor: nil, radius: 14)
      d = round_path(pts, radius)
      a = %(<path d="#{d}" fill="none" stroke="#{c(tone)}" stroke-width="#{sw}" stroke-linecap="round" stroke-linejoin="round" marker-end="url(#ar-#{tone})")
      a += %( marker-start="url(#ar-#{tone})") if both
      a += %( stroke-dasharray="7 7") if dashed
      raw("#{a}/>")
      return self unless label

      lx, ly, anc = at ? [at[0], at[1], anchor || "middle"] : label_point(pts)
      Array(label).each_with_index do |l, i|
        text(lx, ly + i * (size * 1.3).round, l, size: size, weight: 600, fill: tone, anchor: anchor || anc, halo: true, mono: mono)
      end
      self
    end

    def round_path(pts, radius)
      return "M#{pts[0][0]} #{pts[0][1]}L#{pts[1][0]} #{pts[1][1]}" if pts.length == 2

      d = +"M#{pts[0][0]} #{pts[0][1]}"
      pts[1..-2].each_with_index do |p, i|
        a = pts[i]
        b = pts[i + 2]
        r1 = [radius, Math.hypot(p[0] - a[0], p[1] - a[1]) / 2.0].min
        r2 = [radius, Math.hypot(b[0] - p[0], b[1] - p[1]) / 2.0].min
        ia = toward(p, a, r1)
        ib = toward(p, b, r2)
        d << "L#{ia[0]} #{ia[1]}Q#{p[0]} #{p[1]} #{ib[0]} #{ib[1]}"
      end
      d << "L#{pts[-1][0]} #{pts[-1][1]}"
    end

    def toward(from, to, dist)
      len = Math.hypot(to[0] - from[0], to[1] - from[1])
      return from if len.zero?

      [(from[0] + (to[0] - from[0]) * dist / len).round(1), (from[1] + (to[1] - from[1]) * dist / len).round(1)]
    end

    def label_point(pts)
      best = pts.each_cons(2).max_by { |a, b| Math.hypot(b[0] - a[0], b[1] - a[1]) }
      a, b = best
      mx = (a[0] + b[0]) / 2.0
      my = (a[1] + b[1]) / 2.0
      (a[1] - b[1]).abs < (a[0] - b[0]).abs ? [mx, my - 11, "middle"] : [mx + 12, my + 5, "start"]
    end

    def frost(x, y, width, height, title: "Teach", sub: "course server · private to the instructors", zones: [], cols: 1, zone_h: 74, top: 104, seed: 7, title_size: 30, gap: 14)
      id = uid("fr")
      rnd = Random.new(seed)
      rect(x, y + 8, width, height, rx: 26, fill: "#000000", fo: @theme[:shadow] * 0.6, extra: %(filter="url(#soft)"))
      rect(x, y, width, height, rx: 26, fill: :panel)
      raw(%(<clipPath id="#{id}"><rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" rx="26"/></clipPath>))
      blobs = +""
      18.times do |i|
        bx = x + rnd.rand(width)
        by = y + rnd.rand(height)
        col = [c(:teach), c(:reach), c(:teach), c(:instructor)][i % 4]
        case i % 3
        when 0
          blobs << %(<rect x="#{bx.round}" y="#{by.round}" width="#{60 + rnd.rand(150)}" height="#{26 + rnd.rand(70)}" rx="8" fill="#{col}"/>)
        when 1
          blobs << %(<circle cx="#{bx.round}" cy="#{by.round}" r="#{18 + rnd.rand(40)}" fill="#{col}"/>)
        else
          blobs << %(<path d="M#{bx.round} #{by.round}h#{80 + rnd.rand(160)}v#{30 + rnd.rand(90)}h#{40 + rnd.rand(80)}" fill="none" stroke="#{col}" stroke-width="10" stroke-linecap="round"/>)
        end
      end
      raw(%(<g clip-path="url(##{id})"><g filter="url(#frostblur)" opacity="#{@theme[:blob_op]}">#{blobs}</g>))
      raw(%(<rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" fill="#{c(:frost)}" fill-opacity="#{@theme[:frost_op]}"/>))
      raw(%(<rect x="#{x}" y="#{y}" width="#{width}" height="#{height}" fill="url(#hatch)"/></g>))
      rect(x, y, width, height, rx: 26, stroke: :teach, sw: 1.8, so: 0.75)
      rect(x + 5, y + 5, width - 10, height - 10, rx: 22, stroke: :teach, sw: 1, so: 0.22, dash: "2 6")
      badge(x + 46, y + 50, 26, :lock, :teach)
      text(x + 82, y + 50, title, size: title_size, weight: 650, fill: :ink)
      text(x + 82, y + 76, sub, size: 15, fill: :soft)
      zone_grid(x + 22, y + top, width - 44, zones, cols, zone_h, gap)
      self
    end

    def zone_grid(x, y, width, zones, cols, zone_h, gap)
      zw = (width - gap * (cols - 1)) / cols.to_f
      zones.each_with_index do |z, i|
        zx = x + (i % cols) * (zw + gap)
        zy = y + (i / cols) * (zone_h + gap)
        zone(zx, zy, zw, zone_h, z[0], z[1], z[2])
      end
    end

    def zone(x, y, width, height, label, sub = nil, ico = nil)
      rect(x, y, width, height, rx: 14, fill: :zone, fo: @theme[:zone_op], stroke: :teach, sw: 1.2, so: 0.4)
      tx = x + 18
      if ico
        icon(ico, x + 28, y + height / 2.0, 22, :teach)
        tx = x + 52
      end
      if sub
        text(tx, y + height / 2.0 - 3, label, size: 18, weight: 650, fill: :ink)
        text(tx, y + height / 2.0 + 19, sub, size: 14, fill: :soft)
      else
        text(tx, y + height / 2.0 + 6, label, size: 18, weight: 650, fill: :ink)
      end
      circle(x + width - 18, y + 18, 3.5, fill: :teach, fo: 0.8)
    end

    def boundary(x, y, width, height, label, tone: :student, dash: "10 8", label_w: nil)
      rect(x, y, width, height, rx: 30, fill: tone, fo: @theme[:tint] * 0.3, stroke: tone, sw: 1.8, so: 0.75, dash: dash)
      lw = label_w || (tw(label, 14, weight: 600) + 34 + label.length * 1.6).round
      rect(x + 34, y - 15, lw, 30, rx: 15, fill: :bg1)
      rect(x + 34, y - 15, lw, 30, rx: 15, fill: tone, fo: @theme[:tint], stroke: tone, sw: 1.2, so: 0.7)
      text(x + 34 + lw / 2.0, y + 5, label.upcase, size: 13, weight: 700, fill: tone, anchor: "middle", spacing: 1.6)
    end

    def header(no, title, subtitle, wordmark: true)
      text(80, 92, "FIG. #{no}", size: 15, weight: 700, fill: :reach, mono: true, spacing: 3)
      text(80, 146, title, size: 46, weight: 650, fill: :ink)
      text(80, 186, subtitle, size: 21, fill: :soft)
      return self unless wordmark

      mark(@w - 80, 96)
    end

    def mark(xr, y, size: 26)
      spans = %(r<tspan font-weight="650">E</tspan>ach <tspan fill="#{c(:faint)}" font-weight="300">+</tspan> <tspan font-weight="650">Teach</tspan>)
      raw(%(<text x="#{xr}" y="#{y}" text-anchor="end" font-family="#{SANS}" font-size="#{size}" font-weight="300" fill="#{c(:ink)}" letter-spacing="2">#{spans}</text>))
      raw(%(<path d="M#{xr - size * 7.5} #{y + 16}H#{xr}" stroke="url(#warmcool)" stroke-width="3" stroke-linecap="round"/>))
    end

    def footer(legend, note: "github.com/SteveBenner/rEach")
      line(80, @h - 84, @w - 80, @h - 84, stroke: :line, sw: 1)
      x = 80
      legend.each do |tone, label|
        circle(x + 7, @h - 51, 7, fill: tone)
        text(x + 24, @h - 45, label, size: 15, fill: :soft)
        x += 24 + tw(label, 15) + 40
      end
      text(@w - 80, @h - 45, note, size: 14, fill: :faint, anchor: "end", mono: true)
    end

    def base_defs
      t = @theme
      @defs << %(<radialGradient id="bg" cx="#{@w / 2}" cy="#{(@h * 0.42).round}" r="#{(@w * 0.62).round}" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#{t[:bg0]}"/><stop offset=".5" stop-color="#{t[:bg1]}"/><stop offset="1" stop-color="#{t[:bg2]}"/></radialGradient>)
      @defs << %(<linearGradient id="warmcool" gradientUnits="userSpaceOnUse" x1="#{@w - 280}" y1="0" x2="#{@w - 80}" y2="0"><stop offset="0" stop-color="#{t[:student]}"/><stop offset=".45" stop-color="#{t[:student2]}"/><stop offset="1" stop-color="#{t[:reach]}"/></linearGradient>)
      @defs << %(<filter id="soft" x="-20%" y="-20%" width="140%" height="150%"><feGaussianBlur stdDeviation="10"/></filter>)
      @defs << %(<filter id="frostblur" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="16"/></filter>)
      @defs << %(<pattern id="hatch" width="14" height="14" patternUnits="userSpaceOnUse" patternTransform="rotate(38)"><rect width="5" height="14" fill="#{t[:teach]}" fill-opacity="#{t[:hatch_op]}"/></pattern>)
      @defs << %(<pattern id="dots" width="32" height="32" patternUnits="userSpaceOnUse"><circle cx="2" cy="2" r="1.3" fill="#{t[:line]}" fill-opacity="#{t[:deco_op]}"/></pattern>)
      TONES.each do |tone|
        @defs << %(<marker id="ar-#{tone}" viewBox="0 0 10 10" refX="8.6" refY="5" markerWidth="6.5" markerHeight="6.5" orient="auto-start-reverse"><path d="M0 .8L10 5L0 9.2Z" fill="#{t[tone]}"/></marker>)
      end
    end

    def background
      rect(0, 0, @w, @h, fill: "url(#bg)")
      if dark?
        rings = [0.18, 0.3, 0.44, 0.6].map { |k| %(<circle cx="#{@w / 2}" cy="#{(@h * 0.52).round}" r="#{(@w * k).round}"/>) }.join
        raw(%(<g fill="none" stroke="#7dd3fc" stroke-opacity="#{@theme[:deco_op]}" stroke-width="1">#{rings}</g>))
        traces = %(<path d="M#{@w} 34H#{@w - 250}l-22 22"/><path d="M#{@w} #{@h - 30}H#{@w - 150}l-26-26h-90"/><path d="M0 #{@h - 22}H120l20-20"/>)
        raw(%(<g fill="none" stroke="#{c(:reach)}" stroke-opacity=".16" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">#{traces}</g>))
      else
        rect(0, 0, @w, @h, fill: "url(#dots)")
      end
    end

    def to_svg
      head = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@w} #{@h}" width="#{@w}" height="#{@h}" role="img" aria-labelledby="t d">)
      [head, %(<title id="t">#{e(@title)}</title>), %(<desc id="d">#{e(@desc)}</desc>), "<defs>", *@defs, "</defs>", *@out, "</svg>", ""].join("\n")
    end
  end

  REGISTRY = []

  def self.figure(slug, width: 1920, height: 1200, title:, desc:, &block)
    REGISTRY << { slug: slug, width: width, height: height, title: title, desc: desc, block: block }
  end

  def self.render(fig, theme)
    canvas = Canvas.new(fig[:width], fig[:height], theme, title: fig[:title], desc: fig[:desc])
    fig[:block].call(canvas)
    canvas.to_svg
  end
end
