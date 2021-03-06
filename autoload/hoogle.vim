" ----------------------------------------------------------
" Options
" ----------------------------------------------------------

let s:is_nvim = has('nvim')
if s:is_nvim
  let s:window = get(g:, "hoogle_fzf_window", {"window": "call hoogle#floatwindow(32, 132)"})
else
  let s:window = get(g:, "hoogle_fzf_window", {"down": "50%"})
endif

let s:hoogle_path = get(g:, "hoogle_path", "hoogle")
let s:preview_height = get(g:, "hoogle_preview_height", 22)
let s:count = get(g:, "hoogle_count", 500)
let s:header = get(g:, "hoogle_fzf_header",
      \ printf("\x1b[35m%s\x1b[m", 'enter') .. ' - research with query  ' ..
      \ printf("\x1b[35m%s\x1b[m", 'alt-s') .. " - source code\n ")
let s:fzf_preview = get(g:, "hoogle_fzf_preview", "right:60%:wrap")
let s:open_tool = get(g:, "hoogle_open_link", executable("xdg-open") ? "xdg-open" : "")
let s:cacheable_size = get(g:, "hoogle_cacheable_size", 500) * 1000
let s:preview_handler = expand('<sfile>:h:h') .. '/bin/preview.sh'
let s:enable_messages = get(g:, "hoogle_enable_messages", 1)

" Cache only documentation pages, because source code pages rarely exceed 500K
let s:allow_cache = get(g:, "hoogle_allow_cache", 1)
let s:cache_dir = get(g:, "hoogle_cache_dir", $HOME .. "/.cache/fzf-hoogle/")
if !isdirectory(s:cache_dir)
  call mkdir(s:cache_dir, "p")
endif
let s:file = s:cache_dir .. 'query.json'
let s:source_file = s:cache_dir .. 'source.html'

" ----------------------------------------------------------
" Hoogle
" ----------------------------------------------------------

function! s:Message(text) abort
  redraw!
  if s:enable_messages
    echohl WarningMsg
    echo "fzf-hoogle: "
    echohl None
    echon a:text
  endif
endfunction


function! s:GetSourceTail(page, anchor, file_tail) abort
  let anchor = trim(a:anchor)
  let curl_get = "curl -sL -m 10 " .. a:page .. " | "
  let line_with_anchor = "grep -oP 'id=\"" .. anchor .. "\".*?class=\"link\"' "
  " Sometimes there more then one link for anchor so more then one line from grep
  let first_line = "| head -n 1 | "
  let strip_to_link = "sed 's/^.*href=\"\\(.*\\)\" class=\"link\"/\\1/'"

  if !s:allow_cache || a:page !~ '^http'
    return curl_get .. line_with_anchor .. first_line .. strip_to_link
  endif

  let file_path = glob(s:cache_dir .. "*" .. "==" .. a:file_tail)
  let file_exists = file_path != ""
  let page_headers = system("curl -sIL " .. a:page)
  let etag = matchstr(page_headers, 'ETag: "\zs\w\+\ze"')

  if file_exists
    let file_etag = matchstr(file_path, '/\zs\w\+\ze==')
    if etag ==# file_etag
      return line_with_anchor .. file_path .. first_line .. strip_to_link
    else
      call delete(file_path)
    endif
  endif

  let content_size = matchstr(page_headers, 'Content-Length: \zs\d\+\ze')
  if content_size < s:cacheable_size
    return curl_get .. line_with_anchor .. first_line .. strip_to_link
  endif

  let save_file  = "tee " .. s:cache_dir .. etag .. "==" .. a:file_tail .. " | "
  return curl_get .. save_file .. line_with_anchor .. first_line .. strip_to_link
endfunction


function! s:PreviewSourceCode(link) abort
  " We can only get source link from request that have anchor
  " so for module and package items just open default browser with a link
  if a:link !~ '#'
    if s:open_tool != ''
      silent! execute '!' .. s:open_tool .. ' ' .. a:link .. '" &> /dev/null &"'
      call s:Message('The link was sent to a default browser')
    endif
    return
  endif

  call s:Message('Locating source file...')
  let response = {}
  let [page, anchor] = split(a:link, '#')
  let [source_head, file_tail] = split(page, "/docs/")
  let source_tail = trim(system(s:GetSourceTail(page, anchor, file_tail)))
  let source_link = source_head .. "/docs/" .. source_tail
  if source_link =~ '#'
    let [source_page, source_anchor] = split(source_link, '#')
    let source_anchor = hoogle#url#encode(hoogle#url#decode(source_anchor))
    call s:Message('Downloading source file...')
    let text = systemlist("curl -sL -m 10 " .. source_page)
    let line_index = match(text, 'name="' .. source_anchor .. '"')
    let response.linenr = line_index >= 0 ? line_index + 1 : 1
    let response.text = hoogle#url#htmldecode(join(text, "\n"))
    let response.preview_height = s:preview_height
    let response.module_name = matchstr(source_tail, 'src/\zs.\{-1,}\ze\.html#')
  endif

  call s:OpenPreviewWindow(response)
endfunction


function! s:OpenPreviewWindow(dict) abort
  let source_text = get(a:dict, "text", "-- There is no source for this item")

  pclose
  execute 'silent! pedit +setlocal\ buftype=nofile\ nobuflisted\ ' ..
          \ 'noswapfile\ bufhidden=wipe\ filetype=hoogle\ syntax=haskell ' ..
          \ get(a:dict, "module_name", "hoogle")

  execute "normal! \<C-w>P"
  execute "silent! 0put =source_text"
  execute "resize " .. get(a:dict, "preview_height", s:preview_height)
  call cursor(get(a:dict, "linenr", 1), 1)
  execute "normal z\<CR>"
  call s:Message('Done')
  nnoremap <silent><buffer> q <C-w>P:pclose<CR>
  setlocal cursorline
  setlocal nomodifiable
endfunction


function! s:Handler(bang, lines) abort
  " exit if empty for <Esc> hit
  if a:lines == [] || a:lines == ['','','']
    return
  endif

  let keypress = a:lines[1]
  if keypress ==? 'enter'
    let query = a:lines[0]
    call hoogle#run(query, a:bang)
    " fzf on neovim for some reason can't start in insert mode from previous fzf window
    " there is workaround for this
    if s:is_nvim
      call feedkeys('i', 'n')
    endif
    return
  elseif keypress ==? 'alt-s'
    let item = a:lines[2]
    let link = system(printf("jq -r --arg a \"%s\" '. | select(.fzfhquery == \$a) | .url' %s",
                            \ item,
                            \ s:file))
    call s:PreviewSourceCode(link)
  endif
endfunction


function! s:Source(query) abort
  " TODO: since version 5.0.17.13 hoogle properly restrict output of json with --count and --json flags
  " and this operation a little bit faster and use less resources then current restriction with `head`.
  " So should rewrite this after some time.
  let hoogle = printf("%s --json %s 2> /dev/null | ", s:hoogle_path, shellescape(a:query))
  let jq_stream = "jq -cn --stream 'fromstream(1|truncate_stream(inputs))' 2> /dev/null | "
  let items_number = "head -n " .. s:count .. " | "
  let add_path = "jq -c '. | setpath([\"fzfhquery\"]; if .module.name == null then .item else .module.name + \" \" + .item end)' | "
  let remove_duplicates = "awk -F 'fzfhquery' '!seen[$NF]++' | "
  let save_file = "tee " .. s:file .. " | "
  let fzf_lines = "jq -r '.fzfhquery' | "
  let awk_orange = "{ printf \"\033[33m\"$1\"\033[0m\"; $1=\"\"; print $0}"
  let awk_green = "{ printf \"\033[32m\"$1\"\033[0m\"; $1=\"\"; print $0 }"
  let colorize = "awk '{ if ($1 == \"package\" || $1 == \"module\") " .. awk_orange .. "else " .. awk_green .. "}'"
  return hoogle .. jq_stream .. items_number .. add_path .. remove_duplicates .. save_file .. fzf_lines .. colorize
endfunction


function! hoogle#floatwindow(lines, columns) abort
  let v_pos = float2nr((&lines - a:lines) / 2)
  let h_pos = float2nr((&columns - a:columns) / 2)
  let opts = {
      \ 'relative': 'editor',
      \ 'row': v_pos,
      \ 'col': h_pos,
      \ 'height': a:lines,
      \ 'width': a:columns,
      \ 'style': 'minimal'
      \ }
  let buf = nvim_create_buf(v:false, v:true)
  call nvim_open_win(buf, v:true, opts)
endfunction


function! hoogle#run(query, fullscreen) abort
  let prompt = strdisplaywidth(a:query) > 30 ? a:query[:27] .. '.. > ' : a:query .. ' > '
  let options = {
      \ 'sink*': function('s:Handler', [a:fullscreen]),
      \ 'source': s:Source(a:query),
      \ 'options': [
            \ '--no-multi',
            \ '--print-query',
            \ '--expect=enter,alt-s',
            \ '--tiebreak=begin',
            \ '--ansi',
            \ '--exact',
            \ '--inline-info',
            \ '--prompt', prompt,
            \ '--header', s:header,
            \ '--preview', shellescape(s:preview_handler) .. ' ' .. s:file .. ' {} {n}',
            \ '--preview-window', s:fzf_preview,
            \ ]
      \ }
  call extend(options, s:window)

  call fzf#run(fzf#wrap('hoogle', options, a:fullscreen))
endfunction
