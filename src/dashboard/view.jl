"""
Main view function for the Tachikoma dashboard.
"""
function Tachikoma.view(m::ProgressDashboard, f::Frame)
    m.tick += 1
    
    # Poll database for updates
    _poll_database!(m)
    
    buf = f.buffer
    area = f.area
    
    # Outer frame
    outer = Block(
        title = " MultiProgressManagers ",
        border_style = tstyle(:border),
        title_style = tstyle(:title, bold = true)
    )
    main = render(outer, area, buf)
    main.width < 4 && return
    
    # Split into: tab bar | content | status bar
    rows = tsplit(Layout(Vertical, [Fixed(1), Fill(), Fixed(1)]), main)
    length(rows) < 3 && return
    
    tab_area = rows[1]
    content_area = rows[2]
    status_area = rows[3]
    
    # Tab bar
    _render_tab_bar!(m, tab_area, buf)
    
    # Content by tab
    @match m.active_tab begin
        1 => _view_runs_tab!(m, content_area, buf)
        2 => _view_running_tab!(m, content_area, buf)
        _ => nothing
    end

    # Mark-as-failed confirmation modal overlay
    if m.confirm_mark_failed_id !== nothing
        modal = Modal(
            title = "Mark as failed?",
            message = "This experiment is shown as running. Mark it as failed?\n(Useful if the run actually failed but was not updated.)",
            confirm_label = "Mark failed",
            cancel_label = "Cancel",
            selected = m.confirm_modal_selected,
            tick = m.tick
        )
        render(modal, content_area, buf)
    end

    # Status bar
    _render_status_bar!(m, status_area, buf)
end

#TJ|
function _render_tab_bar!(m::ProgressDashboard, area::Rect, buf)
    # Build tab labels
    labels = [
        [Span("1", tstyle(:accent)), Span(" Runs", tstyle(:text))],
        [Span("2", tstyle(:accent)), Span(" Details", tstyle(:text))],
    ]
    active_idx = clamp(m.active_tab, 1, 2)
    
    render(TabBar(labels; active = active_idx), area, buf)
end

"""
Shorten an absolute folder path for the status line: replace the home directory prefix with `~`,
then show at most the last `max_levels` path segments (joined with `/`).
"""
function _format_status_folder_path(path::String; max_levels::Int = 3)::String
    isempty(strip(path)) && return "None"

    p = abspath(path)
    h = homedir()
    display = if !isempty(h) && (p == h || startswith(p, h * "/") || startswith(p, h * "\\"))
        if p == h
            "~"
        else
            rest = p[length(h)+1:end]
            if startswith(rest, "/") || startswith(rest, "\\")
                rest = rest[2:end]
            end
            "~/" * replace(rest, '\\' => '/')
        end
    else
        replace(p, '\\' => '/')
    end

    segs = filter(!isempty, split(display, '/'))
    isempty(segs) && return "None"

    if length(segs) > max_levels
        segs = segs[(end - max_levels + 1):end]
    end

    return join(segs, '/')
end

function _render_status_bar!(m::ProgressDashboard, area::Rect, buf)
    # Build status info
    si = mod1(m.tick ÷ 3, length(SPINNER_BRAILLE))
    
    # Watched folder (shortened)
    folder_label = _format_status_folder_path(m.folder_path; max_levels = 3)
    if folder_label == "None" && !isempty(m.db_path)
        folder_label = _format_status_folder_path(m.db_path; max_levels = 3)
    end
    
    # Running count
    running_count = count(e -> e.status == :running, m.running_experiments)
    
    left = [
        Span(" $(SPINNER_BRAILLE[si]) ", tstyle(:accent)),
        Span(folder_label, tstyle(:primary)),
        Span("  $(DOT)  ", tstyle(:border)),
        Span("$(running_count) running", tstyle(:success)),
        Span("  $(DOT)  ", tstyle(:border)),
        Span("poll: $(m.poll_frequency_ms)ms", tstyle(:text_dim)),
    ]
    
    right_parts = ["[1-2] tabs  [q]uit  [r]efresh  [↑↓]nav"]
    if m.active_tab == 1 && m.confirm_mark_failed_id === nothing
        push!(right_parts, "  [f] mark failed")
    elseif m.active_tab == 2
        push!(right_parts, "  [a/d] divider")
    end
    right = [
        Span(join(right_parts), tstyle(:text_dim))
    ]
    
    render(StatusBar(left = left, right = right), area, buf)
end

