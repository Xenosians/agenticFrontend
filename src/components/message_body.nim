include karax/prelude
import ../api/message_format

proc renderInline(content: string): VNode =
  result = buildHtml(span):
    for part in messageSpans(content):
      case part.kind
      of msText:
        text part.content
      of msStrong:
        strong:
          text part.content
      of msCode:
        code:
          text part.content

proc renderMessageBody*(content: string): VNode =
  result = buildHtml(tdiv(class = "message-body")):
    for part in messageBlocks(content):
      case part.kind
      of mbParagraph:
        p:
          renderInline(part.content)
      of mbHeading:
        h3:
          renderInline(part.content)
      of mbList:
        ul:
          for item in part.items:
            li:
              renderInline(item)
      of mbOrderedList:
        ol:
          for item in part.items:
            li:
              renderInline(item)
      of mbCode:
        pre:
          code:
            text part.content
