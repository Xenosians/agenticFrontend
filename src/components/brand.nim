include karax/prelude


proc renderHydraMark*(
  className: cstring = cstring"hydra-mark"
): VNode =

  result = buildHtml(
    tdiv(class = className)
  ):

    span(class = "hydra-body")

    span(class = "hydra-neck hydra-neck-left"):
      span(class = "hydra-head")

    span(class = "hydra-neck hydra-neck-center"):
      span(class = "hydra-head")

    span(class = "hydra-neck hydra-neck-right"):
      span(class = "hydra-head")