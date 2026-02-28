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
        1 => _view_select_tab!(m, content_area, buf)
        2 => _view_running_tab!(m, content_area, buf)
        3 => _view_stats_tab!(m, content_area, buf)
        4 => _view_admin_tab!(m, content_area, buf)
        _ => nothing
    end
    
    # Status bar
    _render_status_bar!(m, status_area, buf)
end

function _render_tab_bar!(m::ProgressDashboard, area::Rect, buf)
    # Build tab labels
    if m.folder_mode
        labels = [
            [Span("1", tstyle(:accent)), Span(" Select", tstyle(:text))],
            [Span("2", tstyle(:accent)), Span(" Running", tstyle(:text))],
            [Span("3", tstyle(:accent)), Span(" Stats", tstyle(:text))],
            [Span("4", tstyle(:accent)), Span(" Admin", tstyle(:text))],
        ]
        active_idx = m.active_tab
    else
        # Single file mode - skip selector
        labels = [
            [Span("1", tstyle(:accent)), Span(" Running", tstyle(:text))],
            [Span("2", tstyle(:accent)), Span(" Stats", tstyle(:text))],
            [Span("3", tstyle(:accent)), Span(" Admin", tstyle(:text))],
        ]
        active_idx = m.active_tab - 1  # Adjust for skipped tab
    end
    
    render(TabBar(labels; active = active_idx), area, buf)
end

function _render_status_bar!(m::ProgressDashboard, area::Rect, buf)
    # Build status info
    si = mod1(m.tick ÷ 3, length(SPINNER_BRAILLE))
    
    # Connection info
    db_name = if m.folder_mode && m.selected_db_index > 0
        basename(m.available_dbs[m.selected_db_index])
    elseif !isempty(m.db_path)
        basename(m.db_path)
    else
        "None"
    end
    
    # Running count
    running_count = count(e -> e.status == :running, m.running_experiments)
    
    left = [
        Span(" $(SPINNER_BRAILLE[si]) ", tstyle(:accent)),
        Span("DB: ", tstyle(:text_dim)),
        Span(db_name, tstyle(:primary)),
        Span("  $(DOT)  ", tstyle(:border)),
        Span("$(running_count) running", tstyle(:success)),
        Span("  $(DOT)  ", tstyle(:border)),
        Span("poll: $(m.poll_frequency_ms)ms", tstyle(:text_dim)),
    ]
    
    right = [
        Span("[1-4] tabs  [q]uit  [↑↓]nav", tstyle(:text_dim))
    ]
    
    render(StatusBar(left = left, right = right), area, buf)
end
