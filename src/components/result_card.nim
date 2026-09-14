include karax/prelude

import ../app/types


proc renderField(
  field: ResultCardField
): VNode =

  result = buildHtml(
    tdiv(class = "result-card-field")
  ):

    span:
      text field.label

    strong:
      text field.value


proc renderSection(
  section: ResultCardSection
): VNode =

  result = buildHtml(
    tdiv(class = "result-card-section")
  ):

    span(class = "result-card-section-title"):
      text section.title


    case section.kind

    of "preformatted":

      pre(class = "result-card-pre"):
        text section.content


    of "list":

      ul(class = "result-card-list"):

        for item in section.items:

          li:
            text item


    else:

      p(class = "result-card-text"):
        text section.content


proc renderResultCard*(
  card: ResultCard
): VNode =

  result = buildHtml(
    article(class = "result-card")
  ):

    header(class = "result-card-header"):

      tdiv:

        span(class = "result-card-kind"):
          text card.kind

        strong(class = "result-card-title"):
          text card.title


      span(class = "result-card-status"):
        text card.status


    if card.fields.len > 0:

      tdiv(class = "result-card-fields"):

        for field in card.fields:

          renderField(
            field
          )


    if card.sections.len > 0:

      tdiv(class = "result-card-sections"):

        for section in card.sections:

          renderSection(
            section
          )