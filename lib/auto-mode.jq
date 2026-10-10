# The auto-mode entries of the harness layers, merged into Claude Code's user settings, the input.
# Its classifier reads autoMode only there, in managed settings and from --settings, never from a
# repository's .claude/settings.json. Both twins of init run this one filter.
#
#   $e  the entries init read from the layers, one "<list>\t[<layer>] <entry>" per line
#   $l  the names of the layers this run assembled, one per line
#
# An entry of a layer begins with "[<layer>] ". The entries of the layers this run assembled are
# replaced by what those layers carry now; every other entry stays, the person's own and those of
# layers another checkout assembles, and so does "$defaults", which leads a list init creates. An
# entry without a tag whose text a layer now carries gives way to the layer's, so it is not there
# twice. A list whose entries are the same as before is left as it is, in its order.
($e | split("\n") | map(select(length > 0) | split("\t") | {list: .[0], text: .[1]})) as $entries
| ($l | split("\n") | map(select(length > 0))) as $layers
| def layer: (capture("^\\[(?<name>[^\\]]+)\\] ") | .name) // null;
  def untagged: sub("^\\[[^\\]]+\\] "; "");
  reduce ("allow", "environment") as $list (.;
    ([$entries[] | select(.list == $list) | .text]) as $new
    | ([$new[] | untagged]) as $carried
    | .autoMode[$list] as $old
    | if $old == null and ($new | length) == 0 then .
      else
        ([($old // ["$defaults"])[]
          | select((layer as $n | $n != null and ($layers | index([$n])) != null) | not)
          | select((layer == null and (. as $t | $carried | index([$t])) != null) | not)]) as $kept
        | ($kept + $new) as $merged
        | if $old != null and (($old - $merged) | length) == 0 and (($merged - $old) | length) == 0 then .
          else .autoMode[$list] = $merged end
      end)
